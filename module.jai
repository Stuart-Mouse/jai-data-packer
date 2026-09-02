/*
    Data Packer
    
    This data packer works uses type info to pack and unpack binary data.
    It will deep-copy data through pointers and will adjust those pointers as offsets into the binary blob that is output (or conversely, adjust offset back into pointers when deserializing).
    On its own this is only a bit useful, but because we can also serialize type info structures, we can store data along with the metadata that is required to read back in the data itself.
    This leads to the second half of the module, which is for remapping data.
    The remap_data procs will adapt data between similar types, so we can load old files with their corresponding type info file and then adapt that to whatever updated format we are using internally.
    
    Two very basic high-level procedures are provided below for packing and unpacking files with corresponding type info files.
    These are mostly here as basic examples of how to use the pack_data and unpack_data procs and to demonstrate how to use a type info file in conjunction with a target data file.
    This is probably not the way you actually want to do things though, once you get past even a very early phase of a project, becuase it is very inefficient on storage!
    But, I also did not want to really provide a shoddy interface/implementation for managing versioning becuase then the user would proabbyl just want to write their own anyway.
    So instead I'll just outline my own solution for versioning and let you figure out how to implement what you want.
    
    The pack_data() proc further down is what actually does the work of packing data into a file, which basically just means dealing with pointers.
    This proc takes in a pointer to the buffer that it will serialize into so that you can first stick your own header on there if you wish.
    In the header you could simply specify the version for the file, which would tell you which type info file to load so that you can then read the file.
    Then you just have to keep type info files for each file version, which is almost certainly a lot less data than storing a type info file for every single individual file. 
    There's a million different ways you could specify this type info version, and another million ways you may want to configure the header so I just left that up to you!
    Really, this library is just here to do the heavy lifting of the type info and pointer remapping stuff, and it presumes that you can figure out the versioning.
    
    Instead of inserting callbacks for the user to specially serialize certain types or pieces of data, I would encourage the user to just use a different type that represents a file on disk and then write that instead.
    
    For example, we may have the 'Level_Data' runtime struct that represent all level data at runtime, and then a separate 'Level_Data_File' struct that represents how the file is actually structured.
    Then the user can have some really simple transformation from one to the other, allowing the runtime 'Level_Data' struct to change a bit more often and the more stable 'Level_Data_File' struct can be more stable, and maybe even explicitly versioned.
    Say for example the runtime level data uses something like a bucket array or some kind of arena for allocating entities. Well obviously this is not going to be very efficient to store directly.
    So in the level data file struct, one could just use a flat array view instead of the bucket array, and all they would need to do is write a simple procedure to copy between the flat array and the bucket array or arena.
    This is also an easy way to shift to/from a more purpose-built file format from/to the data packer.
    
    
    TODO:
        1. provide some example for handling versioning
        2. finish implementing and provide example of local data pointers for .POINTER, .TYPE, and .PROCEDURE
        2. write versions of remapping procedures that take Any_With_Context, so that user callbacks can be more useful
        3. consider merging remapping and unpacking
            a. main reason being, we can better handle unpacking of unions and pointer recasting
            b. will require using Any_With_Context for both unpacking and remapping procs
    
    TODO: 
        figure out what to do about changes to type info structures between Jai compiler versions
        just got our first taste of this with 0.2.014 and it's already burned most of my day, so we need a robust solution going forwards
        this may also get me to work on the type info history metaprogram plugin thing sooner rather than later
        
        
    DEPENDENCIES: 
        This module depends on my Convert module for remap_data and related functionality.
        
    REFACTORING TODO:
        / create a proper data packer structure that we can use as a sort of context, need to pass fewer parameters as we recurse
        / replace Any_With_Context with a more robust Data_Node system
        allow data packer to handle multiple calls to pack_data, create a directory of top-level data
            this will require some sort of external type table we can index to
*/

#assert(size_of(*void) == size_of(s64));

Pointer_And_Offset :: struct { pointer: *void; offset: s64; };

Data_Packer :: struct {
    buffer:             [..] u8;
    packed_pointers:    [..] Pointer_And_Offset;
    type_table:         [..] *Type_Info;
    table_of_contents:  [..] Table_Of_Contents_Entry;
    
    // TODO: callbacks for recasting pointers and other context settings
    
    // TODO: use chunk system to replace point_and_offset
    //       should be able to have multiple pointers that just point into the same overall chunk
    //       best version will require logic to make chunks bigger after initial creation, but before output file is generated
    //       this will probably mean that we have to defer writing anything to the output buffer until the very end...
    // chunks: [..] Chunk;
    // Chunk :: struct {
    //     pointer:    *void;
    //     offset:     s64;
    //     size:       s64;
    // }
    
    // flags: Flags;
    // Flags :: enum_flags {
    //     DO_GENERATE_TABLE_OF_CONTENTS;
    //     DO_GENERATE_TYPE_TABLE;
    // }
}

// NOTE: returns offset into buffer instead of *void, since we may realloc the buffer at any time
get_bytes :: (packer: *Data_Packer, count: int) -> int {
    count_before := packer.buffer.count;
    array_resize(*packer.buffer, count_before + count);
    return count_before;
}

write_bytes :: inline (packer: *Data_Packer, offset: int, value_pointer: *void, size: int) {
    memcpy(packer.buffer.data + offset, value_pointer, size);
}

write_any :: inline (packer: *Data_Packer, offset: int, any: Any) {
    write_bytes(packer, offset, any.value_pointer, any.type.runtime_size);
}

get_pointer_to_type :: inline (packer: *Data_Packer, offset: int, $TYPE: Type) -> *TYPE {
    assert(offset >= 0 && offset + size_of(TYPE) <= packer.buffer.count, "offset: %, size: %, buffer count: %", offset, size_of(TYPE), packer.buffer.count);
    return (packer.buffer.data + offset).(*TYPE);
}

deinit_packer :: (packer: *Data_Packer) {
    array_free(packer.buffer);
    array_free(packer.packed_pointers);
    packer.* = .{};
}

// packs the given data and its type info and writes each to a separate file
pack_file_with_type_info :: (file_path: string, type_info_file_path: string, data: Any) -> bool {
    {
        packer: Data_Packer;
        defer deinit_packer(*packer);
        
        if !pack_type_info_with_header(*packer, data.type)  return false;
        
        if !write_entire_file(type_info_file_path, packer.buffer.(string)) {
            log("Failed to write type info to file!");
            return false;
        }
    }
    
    {
        packer: Data_Packer;
        defer deinit_packer(*packer);
        
        if !pack_data(*packer, data) {
            log("Failed to pack data!");
            return false;
        }
        
        if !write_entire_file(file_path, packer.buffer.(string)) {
            log("Failed to write data to file!");
            return false;
        }
    }
    
    return true;
}

unpack_file_with_type_info :: (file_path: string, info: *Type_Info, data: Any) -> bool {
    data_file, ok := read_entire_file(file_path);
    if !ok  return false;
    defer free(data_file);
    
    file_data:, ok = unpack_data(info, xx data_file);
    if !ok  return false;
    
    return Convert.any_to_any(data, file_data);
}




// packs any data structure into a single binary blob and remaps pointers relative to start of buffer
// TODO: use a dynamic array so that we don't have to actually realloc as often as we resize the buffer
// TODO: could actually use a flat pool allocator, which would probably simplify code significantly (dont need buffer or write offset then)
//       cannot use flat pool on the web though, so that doesn't help me much at the moment
pack_data :: (packer: *Data_Packer, any: Any, id := "", omit_from_toc := false) -> bool, int {
    recurse :: (
        packer:        *Data_Packer,
        data_node:     *Data_Node,
        write_offset:  s64
    ) -> bool {
        // log("Writing % at offset %", as_type(data_node.type), write_offset);
        // if data_node.type.runtime_size <= 8  log("value: %", data_node.any);
        // log(format_data_trace(data_node,, temp));
        
        base_type := get_variant_base_type(data_node.type);
        if base_type.type == {
          // case .ANY;
          //   any := src.value_pointer.(*Any).*;
            
          //   if !recurse(.{ any.type,          src, null }, buffer, write_offset,     packed_pointers)  return false;
          //   if !recurse(.{ any.value_pointer, src, null }, buffer, write_offset + 8, packed_pointers)  return false;
            
          //   data_write_offset := buffer.count;
          //   array_resize(buffer, buffer.count + any.type.runtime_size);
          //   return recurse(.{ any, src, null }, buffer, data_write_offset, packed_pointers);
            
          case .STRUCT;
            struct_info := base_type.(*Type_Info_Struct);
            
            if struct_info.textual_flags & .UNION {
                if struct_info.textual_flags & .UNION_IS_TAGGED {
                    member_data_node := get_valid_union_member(data_node);
                    if member_data_node {
                        tag_node := get_union_tag(data_node);
                        if !recurse(packer, tag_node, write_offset)  return false;
                        
                        // write valid union member contents
                        if !recurse(packer, member_data_node, write_offset + member_data_node.member_info.offset_in_bytes)  return false;
                    }
                } else {
                    write_any(packer, write_offset, data_node.any);
                }
                return true;
            }
            
            for:members data_node {
                if !recurse(packer, it, write_offset + it.member_info.offset_in_bytes)  return false;
            }
            
          case .ARRAY;
            data_write_offset: s64 = ---;
            
            array_info := base_type.(*Type_Info_Array);
            if array_info.array_type != .FIXED {
                raw_array := data_node.value_pointer.(*Resizable_Array).*;
                
                // when array count is 0, we don't want to set the array's data pointer
                if raw_array.data == null || raw_array.count == 0 {
                    raw_array = .{};
                } else {
                    data_write_offset = get_bytes(packer, array_info.element_type.runtime_size * raw_array.count);
                    raw_array.data = data_write_offset.(*void);
                }
                
                // NOTE: this memcpy is valid for both resizable and slice because we use data_node.type.runtime_size
                write_bytes(packer, write_offset, *raw_array, data_node.type.runtime_size);
            } else {
                data_write_offset = write_offset;
            }
            
            for:elements data_node {
                if !recurse(packer, it, data_write_offset)  return false;
                data_write_offset += array_info.element_type.runtime_size;
            }
            
          case .BOOL;    #through;
          case .ENUM;    #through;
          case .INTEGER; #through;
          case .FLOAT;
            write_any(packer, write_offset, data_node.any);
            
          case .STRING; 
            str := data_node.value_pointer.(*string).*;
            
            data_write_offset := get_bytes(packer, str.count);
            write_bytes(packer, data_write_offset, str.data, str.count);
            
            str.data = data_write_offset.(*u8);
            write_any(packer, write_offset, str);
            
          case .POINTER;
            raw_pointer := data_node.value_pointer.(**void).*;
            if raw_pointer == null {
                write_any(packer, write_offset, null);
                return true;
            }
            
            // maybe recast pointer to more specific type
            pointer_any, is_pointer_to_type_info := recast_type_info(data_node.any);
            
            // TODO: implement user hooks for special pointer handling
            
            // Dereference the pointer and recurse, if the data being pointed at has not already been written.
            pointer_offset: s64 = -1;
            for packer.packed_pointers {
                if it.pointer == raw_pointer { 
                    pointer_offset = it.offset; 
                    break; 
                }
            }
            
            if pointer_offset == -1 {
                type_pointed_to := pointer_any.type.(*Type_Info_Pointer).pointer_to;
                pointer_offset = get_bytes(packer, type_pointed_to.runtime_size);
                array_add(*packer.packed_pointers, .{ raw_pointer, pointer_offset });
                
                // NOTE: We override the type of dereferenced_data_node based on the recast done above.
                dereferenced_data_node := dereference_pointer(data_node);
                dereferenced_data_node.type = type_pointed_to;
                if !recurse(packer, dereferenced_data_node, pointer_offset)  return false;
            }
            
            write_any(packer, write_offset, pointer_offset);
            
            // TODO: Maybe we can just put this inside the above block, and not worry about the uniqueness check?
            if is_pointer_to_type_info {
                array_add_if_unique(*packer.type_table, xx raw_pointer);
            }
        }
        
        return true;
    }
    
    write_offset := get_bytes(packer, any.type.runtime_size);
    
    if !omit_from_toc {
        // if packer.flags & .DO_GENERATE_TABLE_OF_CONTENTS {
            if !id {
                assert(false, "Attempt to pack_data with empty id, while also writing a table of contents.");
            }
            
            for toc_entry: packer.table_of_contents {
                if toc_entry.id == id {
                    assert(false, "Attempt to pack_data with duplicate id: '%'", id);
                }
            }
            
            type_index: int;
            // if packer.flags & .DO_GENERATE_TYPE_TABLE {
                _, type_index = array_add_if_unique(*packer.type_table, any.type);
            // }
            
            array_add(*packer.table_of_contents, .{ id, xx type_index, xx write_offset });
        // }
    }
    
    root_data_node := Data_Node.{ 
        kind = .NO_CONTEXT, 
        name = id, 
        any  = any 
    };
    return recurse(packer, *root_data_node, write_offset), write_offset;
}

// TODO: should probably also use data_node here in case we do run into issues we want to report, even though this code is simpler than the pack_data
// converts pointers in binary blob back into absolute pointers and returns an Any of the base data
// we can't figure out where all pointers are within blob without just doing the whole recursive thing (unless we created some index that gets stored along with file.)
// but we may have multiple pointers that point to the same data
unpack_data :: (type: *Type_Info, buffer: [] u8, offset: s64 = 0, debug_data_name := "data") -> (Any, bool) {
    recurse :: (
        packer:         *Data_Packer,
        data_node:      *Data_Node,
        read_offset:    s64, 
    ) -> bool {
        // print("Unpacking data of type % at offset %\n", as_type(type), read_offset);
        
        base_type := get_variant_base_type(data_node.type);
        if base_type.type == {
          // case .ANY;
            // any := (*buffer.data[read_offset]).(*string);
            // assert(str.data.(u64) >= 0 && str.data.(u64) < buffer.count.(u64));
            // str.data = buffer.data + str.data.(s64);
            
          case .STRUCT;
            struct_info := base_type.(*Type_Info_Struct);
            
            if struct_info.textual_flags & .UNION {
                if struct_info.textual_flags & .UNION_IS_TAGGED {
                    member_data_node := get_valid_union_member(data_node);
                    if member_data_node {
                        if !recurse(packer, member_data_node, read_offset + member_data_node.member_info.offset_in_bytes)  return false;
                    }
                }
                return true;
            }
            
            for:members data_node {
                if !recurse(packer, it, read_offset + it.member_info.offset_in_bytes)  return false;
            }
            
          case .ARRAY;
            // TODO: we should also check pointers for arrays to see if they have been remapped already. theoretically we could have two views pointing at the same data.
            // TODO: we could use fancy pointers in dynamic array allocators to do cool stuff
            
            array_data_offset: s64 = ---;
            array_info := base_type.(*Type_Info_Array);
            if array_info.array_type != .FIXED {
                raw_array := get_pointer_to_type(packer, read_offset, Array_View_64);
                array_data_offset = raw_array.data.(s64);
                
                // To be safe, we make sure the array has valid data and count before trying to unpack it.
                // Previously, we were writing invalid arrays (zero count, non-zero data offset)
                // during packing and it was causing us to have weird behavior here when unpacking.
                if (array_data_offset == 0) != (raw_array.count == 0) {
                    trace := format_data_trace(data_node,, temp);
                    log("%: Invalid array in unpack_data: data offset is %, but count is %.", trace, array_data_offset, raw_array.count);
                    return false;
                }
                
                if array_data_offset < 0 || array_data_offset + raw_array.count > packer.buffer.count {
                    trace := format_data_trace(data_node,, temp);
                    log("%: Invalid array in unpack_data: data offset is % and count is %, but the buffer we are unpacking is only % bytes.", trace, array_data_offset, raw_array.count, packer.buffer.count);
                    return false;
                }
                
                if raw_array.data == null  return true;
                
                raw_array.data = packer.buffer.data + array_data_offset;
            } else {
                array_data_offset = read_offset;
            }
            
            element_read_offset := array_data_offset;
            for:elements data_node {
                if !recurse(packer, it, element_read_offset)  return false;
                element_read_offset += array_info.element_type.runtime_size;
            }
            
          case .STRING;
            // TODO: should check string data pointers with unpacked offsets as well.
            pointer_to_string := get_pointer_to_type(packer, read_offset, string);
            
            string_data_offset := pointer_to_string.data.(s64);
            if string_data_offset < 0 || string_data_offset + pointer_to_string.count > packer.buffer.count {
                trace := format_data_trace(data_node,, temp);
                log("%: Invalid string in unpack_data: data offset is % and count is %, but the buffer we are unpacking is only % bytes.", trace, string_data_offset, pointer_to_string.count, packer.buffer.count);
                return false;
            }
            
            pointer_to_string.data = packer.buffer.data + string_data_offset;
            
          case .POINTER;
            pointer_to_pointer := get_pointer_to_type(packer, read_offset, *void);
            
            packed_pointer := pointer_to_pointer.*;
            if packed_pointer != null {
                // TODO: implement special pointer handling
                
                // overwrite offset with actual pointer
                data_offset := packed_pointer.(s64) & Packed_Pointer_Masks.POINTER_DATA.(s64);
                pointer_to_pointer.* = packer.buffer.data + data_offset;
                
                // after fixing the pointer itself, check if we need to unpack contents pointed to by pointer
                // we will skip unpacking contents pointed to by pointer if we have already unpacked them prior
                for packer.packed_pointers if it.offset == data_offset then return true;
                array_add(*packer.packed_pointers, .{ offset = data_offset });
                
                // maybe recast the pointer to a different type
                // type info cases are built in and run first, then user cases are run
                // NOTE: The type info recast here will only work when unpacking with type info that is not dynamically loaded.
                //       So this will work when we are loading our type info file, but will not do anything when using the loaded type info to unpack a data file.
                //       This should be fine, since your data file probably doesn't contain any pointers to type info, but if they do, note that this recast will not occur!
                pointer_any, done := recast_type_info(Any.{ base_type, pointer_to_pointer });
                
                // NOTE: We override the type of dereferenced_data_node based on the recast done above.
                dereferenced_data_node := dereference_pointer(data_node);
                dereferenced_data_node.type = pointer_any.type.(*Type_Info_Pointer).pointer_to;
                if !recurse(packer, dereferenced_data_node, data_offset)  return false;
            }
        }
        return true;
    }
    
    packer: Data_Packer;
    packer.buffer.data  = buffer.data;
    packer.buffer.count = buffer.count;
    defer array_free(packer.packed_pointers);
    
    assert(offset >= 0 && offset + type.runtime_size <= packer.buffer.count, "unpack_data called with invalid parameters: offset = %, type.runtime_size = %, packer.buffer.count = %", offset, type.runtime_size, packer.buffer.count);
    data_node := Data_Node.{ 
        kind = .NO_CONTEXT, 
        name = debug_data_name, 
        any  = Any.{ type, packer.buffer.data + offset } 
    };
    
    return data_node.any, recurse(*packer, *data_node, offset);
}

/*
    Packed Pointers
    
    When we pack a pointer, we just replace it with a u64 which encodes the offset of the pointed-to data within the data blob.
    The top 32 bits of packed pointer are reserved for special flags that denote special handling for resolving the pointer.
    
    In general, I would probably not use pointers to basic forms of internal data.
    For this purpose you're better off using some kind of integer/enum handle, since that is much easier to remap automatically.
    But for function pointers, it's most practical to just use the function pointer at runtime and do a little bit of extra work for de/serialization 
    For example, you could encode function pointers using an id or string that maps to the function pointer.
*/

// similar to a Recast_Pointer_Proc
// we give the callback the packed pointer and what it's a pointer to, and then the callback can figure out if it is able to resolve the pointer
// this seems better than just using a blind lookup table, since we can consider the context of the type we are pointing to.
// should be much easier for users to implement extended behaviour this way
Pack\ _Local_Data_Pointer_Proc :: #type (pointer: *Data_Node) -> (*void, bool);
Unpack_Local_Data_Pointer_Proc :: #type (packed_pointer: *void, pointer_to: *Type_Info) -> (*void, bool);

// when unpacking local data pointer, we will also want to override the type to match the internal ti, not whetever pointer_to says it is
//      but really, we shouldn't even remap the data behind a local data pointer though, since presumably we just want the raw internal data pointer itself, not to remap from the internal data 
//      currently though, since remapping is done separately after unpacking, we have no way to communicate automatically that a pointer was for internal data and thus should not be remapped...
//      we could collect an array of pointers to all local data pointers and then pass this list to the remap step as some sort of "ignore these pointers" list
// actually, better that we don't require the user to override the type in unpack local data pointer proc, 
//      instead, we will just do the ignore list thing for internal data pointers

Packed_Pointer_Masks :: enum u64 #specified {
    POINTER_DATA :: 0x0000_0000_FFFF_FFFF; // bottom 32 bits used for data offset in blob
    
    // things in the reserved bytes here are subject to change
    // so probably don't rely on these for user-implemented stuff
    RESERVED     :: 0xFFFF_0000_0000_0000; // top 2 bytes reserved for future implementation
    LOCAL_DATA   :: 1 << 63;               // signifies that the pointer should be resolved in reference to some local data
    
    USER         :: 0x0000_FFFF_0000_0000; // bytes 5 & 6 reserved for user-defined flags/data
}

// should only be given a pointer in the packed encoding!
is_local_data_pointer :: inline (pointer: *void) -> bool {
    return pointer.(u64) & Packed_Pointer_Masks.LOCAL_DATA.(u64) != 0;
}

encode_local_data_pointer :: inline (ptr_data: u32, user_data: u16) -> *void {
    return (Packed_Pointer_Masks.LOCAL_DATA.(u64) | (user_data.(u64) << 32) | ptr_data.(u64)).(*void);
}

decode_local_data_pointer :: inline (pointer: *void) -> (ptr_data: u32, user_data: u16) {
    using Packed_Pointer_Masks;
    assert(is_local_data_pointer(pointer));
    return (pointer.(u64) & POINTER_DATA.(u64)).(u32), ((pointer.(u64) & USER.(u64)) >> 32).(u16);
}



#scope_module

#load "old_preload_versions.jai";
#load "type_info.jai";
#load "data_file.jai";

#import "Basic";
#import "File";
Compiler :: #import "Compiler";     // for is_subclass_of

// TODO: Try to remove all of these dependencies!
// #import "Utils"; // TODO: remove array_find_where and remove dependency
using Reflect :: #import "Reflect";
using Convert :: #import "Convert";


recast_type_info :: (any: Any) -> Any, bool {
    if any.type == xx *Type_Info {
        ti := any.value_pointer.(**Type_Info).*;
        if ti.type == {
            case .INTEGER;      return Any.{ xx *Type_Info_Integer,   any.value_pointer }, true;
            case .FLOAT;        return Any.{ xx *Type_Info_Float,     any.value_pointer }, true;
            case .STRING;       return Any.{ xx *Type_Info_String,    any.value_pointer }, true;
            case .POINTER;      return Any.{ xx *Type_Info_Pointer,   any.value_pointer }, true;
            case .PROCEDURE;    return Any.{ xx *Type_Info_Procedure, any.value_pointer }, true;
            case .STRUCT;       return Any.{ xx *Type_Info_Struct,    any.value_pointer }, true;
            case .ARRAY;        return Any.{ xx *Type_Info_Array,     any.value_pointer }, true;
            case .ENUM;         return Any.{ xx *Type_Info_Enum,      any.value_pointer }, true;
            case .VARIANT;      return Any.{ xx *Type_Info_Variant,   any.value_pointer }, true;
        }
    }
    
    // @Hack duplicated above logic for previous preload version
    // Don't want to have to do this for every previous version of type info, so need to think of a better solution.
    // We should probably just implement some proc that adapts old type info binaries into the new format...
    {
        using Preload_0_2_011;
        if any.type == xx *Type_Info {
            ti := any.value_pointer.(**Type_Info).*;
            if ti.type == {
                case .INTEGER;      return Any.{ xx *Type_Info_Integer,   any.value_pointer }, true;
                case .FLOAT;        return Any.{ xx *Type_Info_Float,     any.value_pointer }, true;
                case .STRING;       return Any.{ xx *Type_Info_String,    any.value_pointer }, true;
                case .POINTER;      return Any.{ xx *Type_Info_Pointer,   any.value_pointer }, true;
                case .PROCEDURE;    return Any.{ xx *Type_Info_Procedure, any.value_pointer }, true;
                case .STRUCT;       return Any.{ xx *Type_Info_Struct,    any.value_pointer }, true;
                case .ARRAY;        return Any.{ xx *Type_Info_Array,     any.value_pointer }, true;
                case .ENUM;         return Any.{ xx *Type_Info_Enum,      any.value_pointer }, true;
                case .VARIANT;      return Any.{ xx *Type_Info_Variant,   any.value_pointer }, true;
            }
        }
    }
    
    {
        using Preload_0_2_012;
        if any.type == xx *Type_Info {
            ti := any.value_pointer.(**Type_Info).*;
            if ti.type == {
                case .INTEGER;      return Any.{ xx *Type_Info_Integer,   any.value_pointer }, true;
                case .FLOAT;        return Any.{ xx *Type_Info_Float,     any.value_pointer }, true;
                case .STRING;       return Any.{ xx *Type_Info_String,    any.value_pointer }, true;
                case .POINTER;      return Any.{ xx *Type_Info_Pointer,   any.value_pointer }, true;
                case .PROCEDURE;    return Any.{ xx *Type_Info_Procedure, any.value_pointer }, true;
                case .STRUCT;       return Any.{ xx *Type_Info_Struct,    any.value_pointer }, true;
                case .ARRAY;        return Any.{ xx *Type_Info_Array,     any.value_pointer }, true;
                case .ENUM;         return Any.{ xx *Type_Info_Enum,      any.value_pointer }, true;
                case .VARIANT;      return Any.{ xx *Type_Info_Variant,   any.value_pointer }, true;
            }
        }
    }
    
    {
        using Preload_0_2_025;
        if any.type == xx *Type_Info {
            ti := any.value_pointer.(**Type_Info).*;
            if ti.type == {
                case .INTEGER;      return Any.{ xx *Type_Info_Integer,   any.value_pointer }, true;
                case .FLOAT;        return Any.{ xx *Type_Info_Float,     any.value_pointer }, true;
                case .STRING;       return Any.{ xx *Type_Info_String,    any.value_pointer }, true;
                case .POINTER;      return Any.{ xx *Type_Info_Pointer,   any.value_pointer }, true;
                case .PROCEDURE;    return Any.{ xx *Type_Info_Procedure, any.value_pointer }, true;
                case .STRUCT;       return Any.{ xx *Type_Info_Struct,    any.value_pointer }, true;
                case .ARRAY;        return Any.{ xx *Type_Info_Array,     any.value_pointer }, true;
                case .ENUM;         return Any.{ xx *Type_Info_Enum,      any.value_pointer }, true;
                case .VARIANT;      return Any.{ xx *Type_Info_Variant,   any.value_pointer }, true;
            }
        }
    }
    
    return any, false;
}

Convert_Type_Info_Callback_Data :: struct {
    source_jai_version:     Compiler.Version_Info;
    generated_type_infos:   [..] struct {
        old_ptr:    *void;  
        new_ptr:    *Type_Info;
    };
}

// TODO: figure out how to make allocations better here. going to just push temporary allocator in caller for now so that we don't have to worry about freeing the type info structure we create, since that could get ugly...
convert_type_info :Convert.User_Remap_Proc: (new_info_any: Any, old_info_any: Any, user_data: *void) -> User_Remap_Proc_Result {
    if new_info_any.type != xx *Type_Info then return .UNHANDLED;
    
    using _user_data := user_data.(*Convert_Type_Info_Callback_Data);
    
    old_info_ptr_ptr := old_info_any.value_pointer.(**Type_Info);
    new_info_ptr_ptr := new_info_any.value_pointer.(**Type_Info);
    
    // for now, we will presume that the very basic Type_Info struct in Preload.jai will never change, and we can always access the type tag.
    type_info_tag := old_info_ptr_ptr.*.type;
    
    // the type info of the type info we want to create
    info_type: *Type_Info;
    if type_info_tag == {
      case .INTEGER;               info_type = xx Type_Info_Integer;
      case .FLOAT;                 info_type = xx Type_Info_Float;
      case .STRING;                info_type = xx Type_Info_String;
      case .POINTER;               info_type = xx Type_Info_Pointer;
      case .PROCEDURE;             info_type = xx Type_Info_Procedure;
      case .ARRAY;                 info_type = xx Type_Info_Array;
      case .ENUM;                  info_type = xx Type_Info_Enum;
      case .VARIANT;               info_type = xx Type_Info_Variant;
      case .STRUCT;                info_type = xx Type_Info_Struct;
      case;
        return .UNHANDLED;
        // TODO: do we need a shallow copy here?
    }
    assert(info_type != null, "invalid type info tag: %", type_info_tag);
    
    // check if we've already converted this type info
    found: *type_of(generated_type_infos[0]);
    for *generated_type_infos {
        if it.old_ptr == old_info_ptr_ptr.* {
            found = it;
            break;
        }
    }
    if found {
        new_info_ptr_ptr.* = found.new_ptr;
        return .HANDLED;
    }
    
    // dynamically create a new type info structure for the proper type info subtype
    // then overwrite the type info pointer pointed to by new_info_any 
    _new_info_any := New_Any(info_type);
    new_info_ptr_ptr.* = _new_info_any.value_pointer.(*Type_Info);
    
    array_add(*generated_type_infos, .{ old_info_ptr_ptr.*, new_info_ptr_ptr.* });
    
    _old_info_any := recast_type_info(old_info_any); 
    _old_info_any  = dereference_any_pointer(_old_info_any);
    
    ok := Convert.any_to_any(_new_info_any, _old_info_any);
    return ifx ok then .HANDLED else .ERROR;
}

