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
        
        ok = write_entire_file(type_info_file_path, data.(string));
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
        
        ok = write_entire_file(file_path, data.(string));
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
        (*ti_file).(*[]u8)
    );
    if !ok  return false;
    
    data_file:, ok = read_entire_file(file_path);
    if !ok  return false;
    defer free(data_file);
    
    print("unpacking %\n", file_path);
    data_any:, ok = unpack_data(
        ti_any.value_pointer.(**Type_Info).*,
        (*data_file).(*[]u8)
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
    recurse :: (
        data:           Any, 
        buffer:         *[] u8, 
        write_offset:   s64, 
        pointer_map:    *Table(*void, s64), 
        parent:         Any,
        data_tism:      *Type_Info_Struct_Member
    ) -> bool {
        // print("Writing % at offset %\n", (cast(*Type)*data.type).*, write_offset);
        // print("Writing % at offset %\n", data.type.*, write_offset);
        
        // TODO: should have callback location here to insert special serialization logic for certain types
        //       for example serializing bucket array as a flat array 
        //       obviously should be implemented with corresponding logic for deserializing
        //       But, that could also be very problematic if we don't record in the type info that such fields are specially serialized.
        
        if data.type.type == {
          case .STRUCT;
            ti_struct := data.type.(*Type_Info_Struct);
            
            if ti_struct.textual_flags & .UNION {
                member: *Type_Info_Struct_Member;
                for context.data_packer.conversion_settings.get_union_type_procs {
                    member = it.proc(data.type, data, parent, data_tism, it.data);
                    if member  break;
                }
                // If 'member' was not set, this is not necessarily treated as an error. Perhaps the union was just empty.
                if member {
                    assert(member.flags & .CONSTANT == 0);
                    log("Resolved union member for union of type % to %", (*data.type).(*Type).*, (*member.type).(*Type).*);
                    member_any := Any.{ member.type, data.value_pointer + member.offset_in_bytes };
                    if !recurse(member_any, buffer, write_offset + member.offset_in_bytes, pointer_map, data, member) {
                        return false;
                    }
                }
            }
            
            last_member_offset := -1;
            for member: ti_struct.members {
                if member.flags & .CONSTANT  continue;
                // ignoring #place members. Wish there were a better way to do this.
                if member.offset_in_bytes < last_member_offset  break; 
                last_member_offset = member.offset_in_bytes;
                
                array_add(*debug_trace, member.name);
                defer pop(*debug_trace);
                
                member_any := Any.{ member.type, data.value_pointer + member.offset_in_bytes };
                if !recurse(member_any, buffer, write_offset + member.offset_in_bytes, pointer_map, data, *member) {
                    return false;
                }
            }
            
          case .ARRAY;
            data_offset: s64   = ---; // destination for copied data
            src_data:    *void = ---; // base pointer for source data
            elem_count:  int   = ---;
            
            ti_array := data.type.(*Type_Info_Array);
            if ti_array.array_type != .FIXED {
                raw_array  := data.value_pointer.(*Resizable_Array).*;
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
                array_add(*debug_trace, tprint("[%]", it));
                defer pop(*debug_trace);
                
                if !recurse(elem_any, buffer, data_offset, pointer_map, data, null) {
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
            str     := data.value_pointer.(*string).*;
            str_dst := buffer.count;
            
            // print("Writing string data at offset %\n", str_dst);
            array_resize(buffer, buffer.count + str.count);
            memcpy(*buffer.data[str_dst], str.data, str.count);
            
            str.data = str_dst.(*u8);
            memcpy(*buffer.data[write_offset], *str, size_of(string));
            
          case .POINTER;
            #assert(size_of(*void) == size_of(s64));
            raw_pointer := data.value_pointer.(**void).*;
            if raw_pointer == null {
                memset(*buffer.data[write_offset], 0, size_of(*void));
                return true;
            }
            
            // RECAST POINTER IF NEED BE
            // TODO: generalize this to run through multiple recast procs, breaking when one succeeds
            // Special case, we remap *Type_Info to the specific subtype that it actually is
            _data := recast_type_info(data);
            if data.type != _data.type {
                // print("recast *Type_Info to %\n", (cast(*Type)*_data.type).*);
            }
            
            
            // ENCODE LOCAL DATA POINTERS
            // TODO: generalize this to run through multiple encoding procs, breaking when one succeeds
            // NOTE: how these get encoded and decode is highly contextual! Depends on the type of the pointer and such.
            
            // If pointer is to a very common type info, we specially encode it as such
            // This prevents us from having to actually write that type info out to file
            enumerated_ti := get_enumerated_type_info(_data.value_pointer.(**Type_Info).*);
            if enumerated_ti {
                encoded_ptr := encode_local_data_pointer(enumerated_ti.(u32), 0);
                memcpy(*buffer.data[write_offset], *encoded_ptr, size_of(*void));
                log("encoded enumerated type info pointer for %", _data.value_pointer.(*Type).*);
                return true;
            }
            
            
            // DEREF AND RECURSE, IF NOT ALREADY WRITTEN
            ptr_offset, found := table_find(pointer_map, raw_pointer);
            if !found {
                ptr_offset = buffer.count;
                table_add(pointer_map, raw_pointer, ptr_offset);
                
                ti_derefed := _data.type.(*Type_Info_Pointer).pointer_to;
                array_resize(buffer, buffer.count + ti_derefed.runtime_size);
                
                derefed_any := Any.{ ti_derefed, raw_pointer };
                if !recurse(derefed_any, buffer, ptr_offset, pointer_map, parent, data_tism) {
                    print("Error while packing data for array.\n");
                    return false;
                }
                
                // print("ptr offset %\n", ptr_offset);
            } else {
                // print("Data at % has already been written.\n", raw_pointer);
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
    if !recurse(data, *buffer, 0, *pointer_map, Any.{}, null) {
        free(buffer.data);
        return .[], false;
    }
    
    return buffer, true;
}

// converts pointers in binary blob back into absolute pointers and returns an Any of the base data
// we can't figure out where all pointers are within blob without just doing the whole recursive thing
// but we may have multiple pointers that point to the same data
unpack_data :: (type: *Type_Info, buffer: *[] u8) -> Any, bool {
    recurse :: (
        type:               *Type_Info, 
        buffer:             *[] u8, 
        offset:             s64, 
        unpacked_offsets:   *[..] s64
        // parent:             Any,
        // data_tism:          *Type_Info_Struct_Member,
    ) -> bool {
        // print("Unpacking data of type % at offset %\n", type.*, offset);
        // data := Any.{ type, *buffer[offset] };
        
        if type.type == {
          case .STRUCT;
            ti_struct := type.(*Type_Info_Struct);
            
            // temporary solution, just going to assume unions are trivially copyable and that we don't need to chase down any pointers inside
            // the problem is that we really can't use the type info here in our union resolution procs as we would in remap or pack procs
            // because we can't recognize the type tag value itself. perhaps we could use the type's name to try and do the resolution?
            // Or, theoretically, maybe we should do the remapping at the same time that we are unpacking the data?
            if ti_struct.textual_flags & .UNION {
                return true;
            }
            
            last_member_offset := -1;
            for member: ti_struct.members {
                if member.flags & .CONSTANT  continue;
                // ignoring #place members. Wish there were a better way to do this.
                if member.offset_in_bytes < last_member_offset  break; 
                last_member_offset = member.offset_in_bytes;
                
                array_add(*debug_trace, member.name);
                if !recurse(member.type, buffer, offset + member.offset_in_bytes, unpacked_offsets) {
                    print("Error while unpacking data for struct member.\n");
                    return false;
                }
                pop(*debug_trace);
            }
            
          case .ARRAY;
            data_offset: s64 = ---;
            elem_count:  int = ---;
            
            ti_array := type.(*Type_Info_Array);
            if ti_array.array_type != .FIXED {
                raw_array  := (*buffer.data[offset]).(*Resizable_Array);
                if raw_array.data.(u64) >= buffer.data.(u64) {
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
                array_add(*debug_trace, tprint("[%]", it));
                if !recurse(ti_array.element_type, buffer, data_offset, unpacked_offsets) {
                    print("Error while unpacking data for array.\n");
                    return false;
                }
                data_offset += ti_array.element_type.runtime_size;
                pop(*debug_trace);
            }
            
          case .STRING;
            str := (*buffer.data[offset]).(*string);
            if str.data.(u64) >= buffer.data.(u64) {
                // print("string data pointer was already adjusted...\n");
                return true;
            }
            str.data = buffer.data + str.data.(s64);
            
          case .POINTER;
            ptr_ptr := (*buffer.data[offset]).(**void);
            if ptr_ptr.* != null {
                packed_ptr := ptr_ptr.(**void).*;
                
                if is_local_data_pointer(packed_ptr) {
                    pointer_to := type.(*Type_Info_Pointer).pointer_to;
                    ti_ptr, found := decode_enumerated_type_info_pointer(packed_ptr, pointer_to);
                    if found {
                        ptr_ptr.* = ti_ptr;
                        log("decoded enumerated type info pointer for %", (*ti_ptr).(*Type).*);
                        return true;
                    }
                    
                    // TODO: user callbacks for resolving local data pointers
                }
                
                data_offset := packed_ptr.(s64) & Packed_Pointer_Masks.DATA_OFFSET.(s64);
                
                // assert(derefed_offset < buffer.data.(u64), "pointer @ % was already adjusted!\n", ptr_ptr);
                
                ptr_ptr.* = buffer.data + data_offset;
                // print("offset % -> ptr %\n", derefed_offset, ptr_ptr.*);
                
                // after fixing the pointer itself, check if we need to unpack contents pointed to by pointer
                if array_find(unpacked_offsets.*, data_offset) {
                    // print("data @ ptr was already unpacked\n");
                    return true;
                }
                array_add(unpacked_offsets, data_offset);
                
                _data := recast_type_info(Any.{ type, ptr_ptr });
                if type != _data.type {
                    // print("recast *Type_Info to %\n", (cast(*Type)*_data.type).*);
                }
                
                type_pointed_to := _data.type.(*Type_Info_Pointer).pointer_to;
                if !recurse(type_pointed_to, buffer, data_offset, unpacked_offsets) {
                    print("Error while unpacking data through pointer.\n");
                    return false;
                }
            }
            
        }
        return true;
    }
    
    unpacked_offsets: [..] s64;
    defer array_free(unpacked_offsets);
    
    array_reset_keeping_memory(*debug_trace);
    
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
Resolve_Local_Pointer_Proc :: #type (packed_ptr: *void, pointer_to: *Type_Info) -> (*void, bool);

Packed_Pointer_Masks :: enum u64 #specified {
    DATA_OFFSET  :: 0x0000_0000_FFFF_FFFF; // bottom 32 bits used for data offset in blob
    
    // things in the reserved bytes here are subject to change
    // so probably don't rely on these for user-implemented stuff
    RESERVED     :: 0xFFFF_0000_0000_0000; // top 2 bytes reserved for future implementation
    LOCAL_DATA   :: 1 << 62;               // signifies that the pointer should be resolved in reference to some local data
    
    USER         :: 0x0000_FFFF_0000_0000; // bytes 5 & 6 reserved for user-defined flags/data
}

// should only be given a pointer in the packed encoding!
is_local_data_pointer :: inline (ptr: *void) -> bool {
    return ptr.(u64) & Packed_Pointer_Masks.LOCAL_DATA.(u64) != 0;
}

encode_local_data_pointer :: inline (ptr_data: u32, user_data: u16) -> *void {
    return (Packed_Pointer_Masks.LOCAL_DATA.(u64) | (user_data.(u64) << 32) | ptr_data.(u64)).(*void);
}

decode_local_data_pointer :: inline (ptr: *void) -> (ptr_data: u32, user_data: u16) {
    using Packed_Pointer_Masks;
    assert(is_local_data_pointer(ptr));
    return (ptr.(u64) & DATA_OFFSET.(u64)).(u32), ((ptr.(u64) & USER.(u64)) >> 32).(u16);
}



// enumerates common type infos, used as ids for local pointers
Enumerated_Type_Info :: enum u32 #specified {
    NOT_ENUMERATED ::  0; // used as out-of-band value
    
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
    VOID   :: 13;
    
    PTR_U8     ::  1 | (1 << 31);
    PTR_S8     ::  2 | (1 << 31);
    PTR_U16    ::  3 | (1 << 31);
    PTR_S16    ::  4 | (1 << 31);
    PTR_U32    ::  5 | (1 << 31);
    PTR_S32    ::  6 | (1 << 31);
    PTR_U64    ::  7 | (1 << 31);
    PTR_S64    ::  8 | (1 << 31);
    PTR_F32    ::  9 | (1 << 31);
    PTR_F64    :: 10 | (1 << 31);
    PTR_BOOL   :: 11 | (1 << 31);
    PTR_STRING :: 12 | (1 << 31);
    PTR_VOID   :: 13 | (1 << 31);
}

get_enumerated_type_info :: (ti: *Type_Info) -> Enumerated_Type_Info {
    type := (*ti).(*Type).*;
    if type == {
        case u8;        return .U8;
        case s8;        return .S8;
        case u16;       return .U16;
        case s16;       return .S16;
        case u32;       return .U32;
        case s32;       return .S32;
        case u64;       return .U64;
        case s64;       return .S64;
        case float32;   return .F32;
        case float64;   return .F64;
        case bool;      return .BOOL;
        case string;    return .STRING;
        case void;      return .VOID;
        
        case *u8;        return .PTR_U8;
        case *s8;        return .PTR_S8;
        case *u16;       return .PTR_U16;
        case *s16;       return .PTR_S16;
        case *u32;       return .PTR_U32;
        case *s32;       return .PTR_S32;
        case *u64;       return .PTR_U64;
        case *s64;       return .PTR_S64;
        case *float32;   return .PTR_F32;
        case *float64;   return .PTR_F64;
        case *bool;      return .PTR_BOOL;
        case *string;    return .PTR_STRING;
        case *void;      return .PTR_VOID;
    }
    return .NOT_ENUMERATED;
}

decode_enumerated_type_info_pointer : Resolve_Local_Pointer_Proc : 
    (packed_ptr: *void, pointer_to: *Type_Info) -> (*void, bool)
{
    if !is_type_info_subtype(pointer_to)  return null, false;
    ptr_data, user_data := decode_local_data_pointer(packed_ptr);
    
    if #complete ptr_data.(Enumerated_Type_Info) == {
        case .U8;       return type_info(u8),      true;
        case .S8;       return type_info(s8),      true;
        case .U16;      return type_info(u16),     true;
        case .S16;      return type_info(s16),     true;
        case .U32;      return type_info(u32),     true;
        case .S32;      return type_info(s32),     true;
        case .U64;      return type_info(u64),     true;
        case .S64;      return type_info(s64),     true;
        case .F32;      return type_info(float32), true;
        case .F64;      return type_info(float64), true;
        case .BOOL;     return type_info(bool),    true;
        case .STRING;   return type_info(string),  true;
        case .VOID;     return type_info(void),    true;
        
        case .PTR_U8;       return type_info(*u8),      true;
        case .PTR_S8;       return type_info(*s8),      true;
        case .PTR_U16;      return type_info(*u16),     true;
        case .PTR_S16;      return type_info(*s16),     true;
        case .PTR_U32;      return type_info(*u32),     true;
        case .PTR_S32;      return type_info(*s32),     true;
        case .PTR_U64;      return type_info(*u64),     true;
        case .PTR_S64;      return type_info(*s64),     true;
        case .PTR_F32;      return type_info(*float32), true;
        case .PTR_F64;      return type_info(*float64), true;
        case .PTR_BOOL;     return type_info(*bool),    true;
        case .PTR_STRING;   return type_info(*string),  true;
        case .PTR_VOID;     return type_info(*void),    true;
        
        case .NOT_ENUMERATED; // this also fails
    }
    
    return null, false;
}

is_type_info_subtype :: (ti: *Type_Info) -> bool {
    if ti == {
      case type_info(Type_Info);                return true;
      case type_info(Type_Info_Integer);        return true;
      case type_info(Type_Info_Float);          return true;
      case type_info(Type_Info_Enum);           return true;
      case type_info(Type_Info_String);         return true;
      case type_info(Type_Info_Struct);         return true;
      case type_info(Type_Info_Struct_Member);  return true;
      case type_info(Type_Info_Array);          return true;
      case type_info(Type_Info_Procedure);      return true;
      case type_info(Type_Info_Pointer);        return true;
    }
    return false;
}


debug_trace: [..] string;


#scope_module

// copied from how_to/170_modify.jai
Dynamic_New :: (ti: *Type_Info, initialized := true) -> *void {
    size := ti.runtime_size;
    if size < 0 return null;   // Maybe they gave us a weird polymorphic type for some reason.

    memory := alloc(size);

    if initialized {
        if ti.type == .STRUCT {
            // Structs can have initializers. If the initializer is null, the struct is to be zeroed.
            tis := ti.(*Type_Info_Struct);
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


