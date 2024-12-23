#import "Basic";
#import "File";
#import "Reflection";
#import "Hash_Table";

#load "remap.jai";

/*
    Notes about interface:

    The current approach is to handle unpacking of the type info file and data file, and the data remapping all behind a single procedure call.
    The primary reason for this is the somewhat complicated memory handling involved.
    We have to read in 2 separate files and free the data after doing the remapping.
    So I think it's just safer to do this all behind an API.
    
    If the user needs to load multiple files using the same dynamic type info, 
        then they can probably surmise how to write such a procedure by copying from unpack_file_with_type_info().
    
    Another thing to consider is that we may provide some metaprogram functionality that gets all needed type info data into a single file.
    Then we don't end up duplicating all of the common data structures in every single type info file.
    
*/

// packs the given data and its type info and writes each to a separate file
pack_file_and_type_info :: (file_path: string, type_info_file_path: string, data: Any) -> bool {
    {
        data, ok := pack_data(data.type);
        defer array_free(data);
        if !ok {
            log("Failed to pack type info!\n");
            return false;
        }
        
        ok = write_entire_file(type_info_file_path, cast(string) data);
        if !ok {
            log("Failed to write type info to file!\n");
            return false;
        }
    }
    
    {
        data, ok := pack_data(data);
        defer array_free(data);
        if !ok {
            log("Failed to pack data!\n");
            return false;
        }
        
        ok = write_entire_file(file_path, cast(string) data);
        if !ok {
            log("Failed to write data to file!\n");
            return false;
        }
    }
    
    return true;
}

// assumes that the given file @ type_info_file_path actually contains data that was serialized from a *Type_Info.
unpack_file_with_type_info :: (file_path: string, type_info_file_path: string, data: Any) -> bool {
    ti_file, ok := read_entire_file(type_info_file_path);
    if !ok  return false;
    defer free(ti_file);
    
    print("unpacking %\n", type_info_file_path);
    ti_any:, ok = unpack_data(
        type_info(*Type_Info), 
        cast(*[]u8) *ti_file
    );
    if !ok  return false;
    
    data_file:, ok = read_entire_file(file_path);
    if !ok  return false;
    defer free(data_file);
    
    print("unpacking %\n", file_path);
    data_any:, ok = unpack_data(
        (cast(**Type_Info) ti_any.value_pointer).*,
        cast(*[]u8) *data_file
    );
    if !ok  return false;
    
    return remap_data(data, data_any);
}


// TODO: consider reimplementing the Data_Chunk thing, this will probably give us more flexibility in the future

// TODO: Perhaps all array types should just be encoded as array views. 
//       This breaks the ability to simply memcpy many data types, but we already weren't able to do that...
//       Plus, we're already gonna do some weird stuff for procedure pointers methinks
//       First, need to just better cosider when we can shortcut with a memcpy
//           we can memcpy structs when there are no pointers involved and types are equivalent
//           we can memcpy fixed arrays if inner type is memcpy-able


// packs any data structure into a single binary blob and remaps pointers relative to start of buffer
pack_data :: (data: Any) -> ([] u8, bool) {
    recurse :: (data: Any, buffer: *[] u8, write_offset: s64, pointer_map: *Table(*void, s64)) -> bool {
        // print("Writing % at offset %\n", (cast(*Type)*data.type).*, write_offset);
        // print("Writing % at offset %\n", data.type.*, write_offset);
        
        if data.type.type == {
          case .STRUCT;
            ti_struct := cast(*Type_Info_Struct) data.type;
            for ti_struct.members {
                member_any := Any.{ it.type, data.value_pointer + it.offset_in_bytes };
                if !recurse(member_any, buffer, write_offset + it.offset_in_bytes, pointer_map) {
                    // print("Error while packing data for array.\n");
                    return false;
                }
            }
            
          case .ARRAY;
            data_offset : s64   = ---; // destination for copied data
            src_data    : *void = ---; // base pointer for source data
            elem_count  : int   = ---;
            
            ti_array := cast(*Type_Info_Array) data.type;
            if ti_array.array_type != .FIXED {
                raw_array  := (cast(*Resizable_Array) data.value_pointer).*;
                src_data    = raw_array.data;
                elem_count  = raw_array.count;
                data_offset = buffer.count; // elements will be written to end of buffer
                
                raw_array.data = xx buffer.count;                                         // adjust data pointer in raw array before writing
                memcpy(*buffer.data[write_offset], *raw_array, data.type.runtime_size);   // this will work for both resizable and slice because we use the orig data any's runtime size
                
                // array resize here makes space for the data of resizable array / array view
                array_resize(buffer, buffer.count + (ti_array.element_type.runtime_size * raw_array.count));
            } else {
                src_data    = data.value_pointer;
                elem_count  = ti_array.array_count;
                data_offset = write_offset;
            }
            
            elem_any := Any.{ ti_array.element_type, src_data };
            for 0..elem_count-1 {
                if !recurse(elem_any, buffer, data_offset, pointer_map) {
                    print("Error while packing data for array.\n");
                    return false;
                }
                elem_any.value_pointer += ti_array.element_type.runtime_size;
                data_offset            += ti_array.element_type.runtime_size;
            }
            
          case .BOOL;    #through;
          case .ENUM;    #through;
          case .INTEGER; #through;
          case .FLOAT;   
            memcpy(*(buffer.data[write_offset]), data.value_pointer, data.type.runtime_size);
          
          case .STRING;
            str     := (cast(*string) data.value_pointer).*;
            str_dst := buffer.count;
            
            // print("Writing string data at offset %\n", str_dst);
            array_resize(buffer, buffer.count + str.count);
            memcpy(*buffer.data[str_dst], str.data, str.count);
            
            str.data = xx str_dst;
            memcpy(*buffer.data[write_offset], *str, size_of(string));
            
          case .POINTER;
            #assert(size_of(*void) == size_of(s64));
            raw_pointer := (cast(**void)data.value_pointer).*;
            if raw_pointer == null {
                memset(*buffer.data[write_offset], 0, size_of(*void));
                return true;
            }
            
            // Special case, we remap *Type_Info to the specific subtype that it actually is
            _data := recast_type_info(data);
            if data.type != _data.type {
                // print("recast *Type_Info to %\n", (cast(*Type)*_data.type).*);
            }
            
            ti_derefed := (cast(*Type_Info_Pointer)_data.type).pointer_to;
        
            ptr_offset, found := table_find(pointer_map, raw_pointer);
            if !found {
                ptr_offset = buffer.count;
                table_add(pointer_map, raw_pointer, ptr_offset);
                
                array_resize(buffer, buffer.count + ti_derefed.runtime_size);
                
                derefed_any := Any.{ ti_derefed, raw_pointer };
                if !recurse(derefed_any, buffer, ptr_offset, pointer_map) {
                    print("Error while packing data for array.\n");
                    return false;
                }
                
                // print("ptr offset %\n", ptr_offset);
            } else {
                // print("Data at pointer address has already been written.\n");
            }
            
            memcpy(*buffer.data[write_offset], *ptr_offset, size_of(*void));
        }
        
        // print("Buffer is %, %\n", buffer.data, buffer.count);
        return true;
    }
    
    buffer: [] u8;
    pointer_map: Table(*void, s64);
    defer deinit(*pointer_map);
    
    array_resize(*buffer, data.type.runtime_size);
    if !recurse(data, *buffer, 0, *pointer_map) {
        free(buffer.data);
        return .[], false;
    }
    
    return buffer, true;
}

debug_idents : [..] string;

// converts pointers in binary blob back into absolute pointers and returns an Any of the base data
// we can't figure out where all pointers are within blob without just doing the whole recursive thing
// but we may have multiple pointers that point to the same data
unpack_data :: (type: *Type_Info, buffer: *[] u8) -> Any, bool {
    recurse :: (type: *Type_Info, buffer: *[] u8, offset: s64, unpacked_offsets: *[..] s64) -> bool {
        // print("Unpacking data of type % at offset %\n", type.*, offset);
        
        if type.type == {
          case .STRUCT;
            ti_struct := cast(*Type_Info_Struct) type;
            for ti_struct.members {
                array_add(*debug_idents, it.name);
                if !recurse(it.type, buffer, offset + it.offset_in_bytes, unpacked_offsets) {
                    print("Error while unpacking data for struct member.\n");
                    return false;
                }
                pop(*debug_idents);
            }
            
          case .ARRAY;          
            data_offset : s64 = ---;
            elem_count  : int = ---;
            
            ti_array := cast(*Type_Info_Array) type;
            if ti_array.array_type != .FIXED {
                raw_array  := cast(*Resizable_Array) *buffer.data[offset];
                if cast(u64) raw_array.data >= cast(u64) buffer.data {
                    // print("array data pointer was already adjusted...\n");
                    return true;
                }
                data_offset = xx raw_array.data;
                elem_count  = raw_array.count;
                raw_array.data = xx (buffer.data + data_offset);
            } else {
                data_offset = offset;
                elem_count  = ti_array.array_count;
            }
            
            for 0..elem_count-1 {
                array_add(*debug_idents, tprint("[%]", it));
                if !recurse(ti_array.element_type, buffer, data_offset, unpacked_offsets) {
                    print("Error while unpacking data for array.\n");
                    return false;
                }
                data_offset += ti_array.element_type.runtime_size;
                pop(*debug_idents);
            }
            
          case .STRING;
            str := (cast(*string) *buffer.data[offset]);
            if cast(u64) str.data >= cast(u64) buffer.data {
                // print("string data pointer was already adjusted...\n");
                return true;
            }
            str.data = xx (buffer.data + cast(s64) str.data);
            
          case .POINTER;
            ptr_ptr := (cast(**void) *buffer.data[offset]);
            if ptr_ptr.* != null {
                // TODO: I dont think any of the pointer correcting logic will work until we change this logic
                // We need to actually check ptr_ptr against a list of already adjusted pointers instead of this hacky method
                derefed_offset := cast(u64) ptr_ptr.*;
                // print("adjusting ptr @ (%) % %\n", ptr_ptr, derefed_offset, debug_idents);
                
                if derefed_offset >= cast(u64) buffer.data {
                    assert(false, "pointer @ % was already adjusted!\n", ptr_ptr);
                    return true;
                }
                
                ptr_ptr.* = xx (buffer.data + derefed_offset);
                // print("offset % -> ptr %\n", derefed_offset, ptr_ptr.*);
                
                if array_find(unpacked_offsets.*, cast(s64) derefed_offset) {
                    // print("data @ ptr was already unpacked\n");
                    return true;
                }
                
                array_add(unpacked_offsets, cast(s64) derefed_offset);
                
                _data := recast_type_info(Any.{ type, ptr_ptr });
                if type != _data.type {
                    // print("recast *Type_Info to %\n", (cast(*Type)*_data.type).*);
                }
                
                ti_derefed := (cast(*Type_Info_Pointer)_data.type).pointer_to;
                if !recurse(ti_derefed, buffer, cast(s64) derefed_offset, unpacked_offsets) {
                    print("Error while unpacking data through pointer.\n");
                    return false;
                }
            }
            
        }
        return true;
    }
    
    unpacked_offsets: [..] s64;
    defer array_free(unpacked_offsets);
    
    array_reset_keeping_memory(*debug_idents);
    
    if !recurse(type, buffer, 0, *unpacked_offsets) {
        return Any.{}, false;
    }
    
    return Any.{ type, *buffer.data[0] }, true;
}




/*
    Packed Pointers
    
    When we pack a pointer, we just replace it with a u64 which encodes the offset of the pointed-to data within the data blob.

    The top 32 bits of packed pointer are reserved for special flags that denote special handling for resolving the pointer.
    
    For example, we can use the highest bit to denote that a pointer should resolve to some local data which is not in the packed data.
    We use this for common type_info's that we would not ever want to serialize, reducing bloat.
    For these common type_info's, we just use the bottom 32 bits as an ID for looking up the actual type_info pointer we need.
    
    The special pointer resolution is implemented through callbacks so that users can do whatever they wish when resolving a pointer.
    
    At the moment, the LOCAL_DATA flag is the only one defined, but I may add some additional flags in the future.
    So, I have reserved the top 2 bytes for myself, but feel free to define your own flags in the next 2 highest bytes
    
*/

// similar to a Recast_Pointer_Proc
// we give the callback the packed pointer and what it's a pointer to, and then the callback can figure out if it is able to resolve the pointer
// this seems better than just using a blind lookup table, since we can consider the context of the type we are pointing to.
// should be much easier for users to implement extended behaviour this way
Resolve_Local_Pointer_Proc :: #type (packed_ptr: u64, pointer_to: *Type_Info) -> (*void, bool);

Packed_Pointer_Masks :: enum u64 #specified {
    DATA_OFFSET :: 0x0000_0000_FFFF_FFFF; // bottom 32 bits used for data offset in blob
    
    RESERVED    :: 0xFFFF_0000_0000_0000; // top 2 bytes reserved for future implementation
    LOCAL_DATA  :: 1 << 63;               // signifies that the pointer should be resolved in reference to some local data
    
    USER        :: 0x0000_FFFF_0000_0000; // bytes 5 & 6 reserved for user-defined flags
}

// enumerates common type infos, used as ids for local pointers
Common_Type_Infos :: enum u32 #specified {
    VOID   ::  0;
    U8     ::  1;
    S8     ::  2;
    U16    ::  3;
    S16    ::  4;
    U32    ::  5;
    S32    ::  6;
    U64    ::  7;
    S64    ::  8;
    F32    ::  9;
    F64    :: 10;
    BOOL   :: 11;
    STRING :: 12;
}

resolve_common_type_info_pointer : Resolve_Local_Pointer_Proc : 
    (packed_ptr: u64, pointer_to: *Type_Info) -> (*void, bool)
{
    if !is_type_info_subtype(pointer_to)  return null, false;
    
    ti_id := cast(Common_Type_Infos) (packed_pointer & cast(u64) Packed_Pointer_Masks.DATA_OFFSET);
    
    // if ti_id is not one of our enumerated values, then we can't resolve it
    if !array_find(type_info(Common_Type_Infos).values, ti_id)  return null, false;
    
    if #complete ti_id == {
        case .VOID   ; return void;
        case .U8     ; return u8;
        case .S8     ; return s8;
        case .U16    ; return u16;
        case .S16    ; return s16;
        case .U32    ; return u32;
        case .S32    ; return s32;
        case .U64    ; return u64;
        case .S64    ; return s64;
        case .F32    ; return float32;
        case .F64    ; return float64;
        case .BOOL   ; return bool;
        case .STRING ; return string;
    }
    
    return null, false;
}

is_type_info_subtype :: (ti: *Type_Info) -> bool {
    if ti == {
      case type_info(Type_Info); return true;
      case type_info(Type_Info_Integer); return true;
      case type_info(Type_Info_Float); return true;
      case type_info(Type_Info_Enum); return true;
      case type_info(Type_Info_Bool); return true;
      case type_info(Type_Info_String); return true;
      case type_info(Type_Info_Struct); return true;
      case type_info(Type_Info_Struct_Member); return true;
      case type_info(Type_Info_Array); return true;
      case type_info(Type_Info_Procedure); return true;
      case type_info(Type_Info_Pointer); return true;
    }
    return false;
}



#scope_module

// copied from how_to/170_modify.jai
Dynamic_New :: (ti: *Type_Info, initialized := true) -> *void {
    size := ti.runtime_size;
    if size < 0 return null;   // Maybe they gave us a weird polymorphic type for some reason.

    memory := alloc(size);

    if initialized {
        if ti.type == .STRUCT {
            // Structs can have initializers. If the initializer is null, the struct is to be zeroed.
            tis := cast(*Type_Info_Struct) ti;
            if tis.initializer  tis.initializer(memory);
            else                memset(memory, 0, size);
        } else {
            // Non-structs always default to 0.
            // @Incomplete: Here we are not handling variants, or arrays of things that might have initializers.
            memset(memory, 0, size);
        }
    }

    return memory;
}

Dynamic_New_Any :: inline (ti: *Type_Info, initialized := true) -> Any {
    memory := Dynamic_New(ti, initialized);
    return ifx memory then Any.{ ti, memory } else Any.{};
}

array_reserve_nonpoly :: (array: *Resizable_Array, desired_items: s64, elem_size: s64) {
    if desired_items <= array.allocated return;
    
    if !array.allocator.proc  remember_allocators(array);
    
    array.data = realloc(array.data, desired_items * elem_size, array.allocated * elem_size,, array.allocator);
    assert(array.data != null); // The program will die if we couldn't get memory. We can think about an alternative strategy, but it's hard to know what would be reasonable.
    
    array.allocated = desired_items;
}
