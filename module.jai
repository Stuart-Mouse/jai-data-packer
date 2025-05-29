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
*/


// TODO: figure out how we want to do data packer settings after we figure out the type info versioning issue
// #add_context data_packer_settings: Data_Packer_Settings;
// Data_Packer_Settings :: struct {
//     pointer_recast_procs:   [..] struct { proc: Pointer_Recast_Proc; data: *void; };
// }


// packs the given data and its type info and writes each to a separate file
pack_file_with_type_info :: (file_path: string, type_info_file_path: string, data: Any) -> bool {
    {
        buffer: [] u8;
        defer array_free(buffer);
        
        if !pack_type_info_with_header(data.type, *buffer)  return false;
        
        if !write_entire_file(type_info_file_path, buffer.(string)) {
            log("Failed to write type info to file!");
            return false;
        }
    }
    
    {
        buffer: [] u8;
        defer array_free(buffer);
        
        if !pack_data(data, *buffer) {
            log("Failed to pack data!");
            return false;
        }
        
        if !write_entire_file(file_path, buffer.(string)) {
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
    
    file_data:, ok = unpack_data(info, xx *data_file);
    if !ok  return false;
    
    return Convert.any_to_any(data, file_data);
}



// packs any data structure into a single binary blob and remaps pointers relative to start of buffer
// TODO: use a dynamic array so that we don't have to actually realloc as often as we resize the buffer
// TODO: could actually use a flat pool allocator, which would probably simplify code significantly (dont need buffer or write offset then)
pack_data :: (data: Any, buffer: *[]u8) -> bool {
    Pointer_And_Offset :: struct { pointer: *void; offset: s64; };
    
    recurse :: (
        src_ctx:            Any_With_Context,
        buffer:             *[] u8, 
        write_offset:       s64, 
        packed_pointers:    *[..] Pointer_And_Offset
    ) -> bool {
        // print("Writing % at offset %\n", (*data.type).(*Type).*, write_offset);
        src := src_ctx.any;
        
        if src.type.type == {
          case .STRUCT;
            struct_info := src.type.(*Type_Info_Struct);
            
            if struct_info.textual_flags & .UNION {
                union_member_info: *Type_Info_Struct_Member;
                for context.conversion_settings.get_union_type_procs {
                    union_member_info = it.proc(src.type, src_ctx, it.data);
                    if union_member_info  break;
                }
                // If 'member' was not set, this is not necessarily treated as an error. Perhaps the union was just empty.
                if union_member_info {
                    assert(union_member_info.flags & .CONSTANT == 0);
                    union_member := get_member(src, union_member_info);
                    if !recurse(.{ union_member, src, union_member_info }, buffer, write_offset + union_member_info.offset_in_bytes, packed_pointers) {
                        return false;
                    }
                }
            }
            
            iterate_struct_members(src, .SKIP_CONSTANT | .SKIP_PLACE, #code {
                add_debug_trace(".%", it_info.name);
                if !recurse(.{ it, src, it_info }, buffer, write_offset + it_info.offset_in_bytes, packed_pointers) {
                    return false;
                }
            });
            
          case .ARRAY;
            data_write_offset: s64   = ---;
            array_data:        *void = ---;
            array_count:       int   = ---;
            
            ti_array := src.type.(*Type_Info_Array);
            if ti_array.array_type != .FIXED {
                raw_array        := src.value_pointer.(*Resizable_Array).*;
                array_data        = raw_array.data;
                array_count       = raw_array.count;
                data_write_offset = buffer.count; // elements will be written to end of buffer
                
                // when array count is 0, we don't want to set the array's data pointer
                if raw_array.data == null || raw_array.count == 0 {
                    raw_array = .{}; // just make it all zero'd to be safe
                } else {
                    raw_array.data = data_write_offset.(*void);
                    array_resize(buffer, buffer.count + (ti_array.element_type.runtime_size * raw_array.count));
                }
                memcpy(*buffer.data[write_offset], *raw_array, src.type.runtime_size);   // this will work for both resizable and slice because we use src.type.runtime_size
            } else {
                array_data        = src.value_pointer;
                array_count       = ti_array.array_count;
                data_write_offset = write_offset;
            }
            
            elem_any := Any.{ ti_array.element_type, array_data };
            for 0..array_count-1 {
                add_debug_trace("[%]", it);
                if !recurse(.{ elem_any, src, null }, buffer, data_write_offset, packed_pointers) {
                    print("Error while packing data for array.\n");
                    return false;
                }
                elem_any.value_pointer += ti_array.element_type.runtime_size;
                data_write_offset      += ti_array.element_type.runtime_size;
            }
            
          case .BOOL;    #through;
          case .ENUM;    #through;
          case .INTEGER; #through;
          case .FLOAT;   
            memcpy(*buffer.data[write_offset], src.value_pointer, src.type.runtime_size);
            
          case .STRING;
            str := src.value_pointer.(*string).*;
            data_write_offset := buffer.count;
            
            array_resize(buffer, buffer.count + str.count);
            memcpy(*buffer.data[data_write_offset], str.data, str.count);
            
            str.data = data_write_offset.(*u8);
            memcpy(*buffer.data[write_offset], *str, size_of(string));
            
          case .POINTER;
            #assert(size_of(*void) == size_of(s64));
            raw_pointer := src.value_pointer.(**void).*;
            if raw_pointer == null {
                memset(*buffer.data[write_offset], 0, size_of(*void));
                return true;
            }
            
            // maybe recast pointer to more specific type
            ptr_any, done := recast_type_info(src);
            // if !done {
            //     for context.conversion_settings.pointer_recast_procs {
            //         recast_ptr_any:, done = it.proc(.{ ptr_any, src_ctx.parent, src_ctx.struct_member_info }, it.data);
            //         if done { ptr_any = recast_ptr_any; break; }
            //     }
            // }
            // if ptr_any.type != src.type {
            //     // print("recast a pointer: % -> %\n", (*src.type).(*Type).*, (*ptr_any.type).(*Type).*);
            // }
            
            // ENCODE LOCAL DATA POINTERS
            // pack_local_ptr := context.pack_local_data_pointer;
            // if pack_local_ptr != null {
            //     ptr_data, ok := pack_local_ptr(_data, parent, data_tism);
            //     if !ok {
            //         log("Error encountered while trying to pack local data pointer!");
            //         return false;
            //     }
            //     memcpy(*buffer.data[write_offset], *ptr_data, size_of(*void));
            //     return true; // we don't need to continue to pack data below, since it is internal data
            // }
            
            // DEREF AND RECURSE, IF NOT ALREADY WRITTEN
            ptr_offset := -1;
            for packed_pointers.*  if it.pointer == raw_pointer { ptr_offset = it.offset; break; };
            if ptr_offset == -1 {
                ptr_offset = buffer.count;
                array_add(packed_pointers, .{ raw_pointer, ptr_offset });
                
                type_pointed_to := ptr_any.type.(*Type_Info_Pointer).pointer_to;
                array_resize(buffer, buffer.count + type_pointed_to.runtime_size);
                
                // current parent and struct member info passed through pointer dereference
                derefed_any := Any.{ type_pointed_to, raw_pointer };
                if !recurse(.{ derefed_any, src_ctx.parent, src_ctx.struct_member_info }, buffer, ptr_offset, packed_pointers) {
                    print("Error while packing data for array.\n");
                    return false;
                }
            }
            
            memcpy(*buffer.data[write_offset], *ptr_offset, size_of(*void));
        }
        
        return true;
    }
    
    packed_pointers: [..] Pointer_And_Offset;
    defer array_free(packed_pointers);
    
    #if DEBUG  array_reset_keeping_memory(*debug_trace);
    add_debug_trace("DATA");
    
    array_resize(buffer, buffer.count + data.type.runtime_size);
    if !recurse(.{ any = data }, buffer, 0, *packed_pointers) {
        return false;
    }
    
    return true;
}

// converts pointers in binary blob back into absolute pointers and returns an Any of the base data
// we can't figure out where all pointers are within blob without just doing the whole recursive thing
// but we may have multiple pointers that point to the same data
unpack_data :: (type: *Type_Info, buffer: *[] u8) -> (Any, bool) {
    recurse :: (
        type:               *Type_Info, 
        buffer:             *[] u8, 
        read_offset:        s64, 
        unpacked_offsets:   *[..] s64
    ) -> bool {
        // print("Unpacking data of type % at offset %\n", recast_type_info(Any.{ type, *buffer[read_offset] }), offset);
        
        if type.type == {
          case .STRUCT;
            ti_struct := type.(*Type_Info_Struct);
            
            // temporary solution, just going to assume unions are trivially copyable and that we don't need to chase down any pointers inside
            // the problem is that we really can't use the type info here in our union resolution procs as we would in remap or pack procs
            // because we can't recognize the type tag value itself. perhaps we could use the type's name to try and do the resolution?
            // Or, theoretically, maybe we should do the remapping at the same time that we are unpacking the data?
            if ti_struct.textual_flags & .UNION  return true;
            
            struct_any := Any.{ type, *buffer[read_offset] };
            iterate_struct_members(struct_any, .SKIP_CONSTANT | .SKIP_PLACE, #code {
                add_debug_trace(".%", it_info.name);
                if !recurse(it.type, buffer, read_offset + it_info.offset_in_bytes, unpacked_offsets) {
                    print("Error while unpacking data for struct member.\n");
                    return false;
                }
            });
            
          case .ARRAY;
            array_data:  s64 = ---;
            array_count: int = ---;
            
            ti_array := type.(*Type_Info_Array);
            if ti_array.array_type != .FIXED {
                raw_array := (*buffer.data[read_offset]).(*Resizable_Array);
                
                // to be safe, make sure array has valid data and count before trying to unpack
                // previously, we were writing invalid arrays (zero count, non-zero data offset) during packing and it was causing us to have weird behavior here when unpacking
                if raw_array.data  == null  return true;
                if raw_array.count == 0     return true;
                
                if raw_array.data.(u64) < 0 || raw_array.data.(u64) >= buffer.count.(u64) {
                    print("Error while unpacking data for array.\n");
                    log("raw_array: %", raw_array.*);
                    log("path: %", debug_trace);
                    return false;
                }
                array_data     = raw_array.data.(s64);
                array_count    = raw_array.count;
                raw_array.data = buffer.data + array_data;
            } else {
                array_data  = read_offset;
                array_count = ti_array.array_count;
            }
            
            elem_read_offset := array_data;
            for 0..array_count-1 {
                add_debug_trace("[%]", it);
                if !recurse(ti_array.element_type, buffer, elem_read_offset, unpacked_offsets) {
                    print("Error while unpacking data for array.\n");
                    return false;
                }
                elem_read_offset += ti_array.element_type.runtime_size;
            }
            
          case .STRING;
            str := (*buffer.data[read_offset]).(*string);
            assert(str.data.(u64) >= 0 && str.data.(u64) < buffer.count.(u64));
            str.data = buffer.data + str.data.(s64);
            
          case .POINTER;
            ptr_ptr := (*buffer.data[read_offset]).(**void);
            if ptr_ptr.* != null {
                packed_ptr := ptr_ptr.(**void).*;
                
                // if is_local_data_pointer(packed_ptr) {
                //     unpack_local_ptr := context.unpack_local_data_pointer;
                //     if unpack_local_ptr == null {
                //         log("Error: encountered a local data pointer, but context.unpack_local_data_pointer was null.");
                //         return false;
                //     }
                    
                //     pointer_to := type.(*Type_Info_Pointer).pointer_to;
                //     local_data_ptr, ok := unpack_local_ptr(packed_ptr, pointer_to);
                //     if !ok {
                //         log("Error while trying to unpack local data pointer.");
                //         return false;
                //     }
                    
                //     ptr_ptr.* = local_data_ptr;
                //     if local_data_ptrs then array_add(local_data_ptrs, local_data_ptr);
                //     return true;
                // }
                
                // overwrite offset with actual pointer
                data_offset := packed_ptr.(s64) & Packed_Pointer_Masks.POINTER_DATA.(s64);
                ptr_ptr.* = buffer.data + data_offset;
                
                // after fixing the pointer itself, check if we need to unpack contents pointed to by pointer
                // we will skip unpacking contents pointed to by pointer if we have already unpacked them prior
                if array_find(unpacked_offsets.*, data_offset) then return true;
                array_add(unpacked_offsets, data_offset);
                
                // maybe recast the pointer to a different type
                // type info cases are built in and run first, then user cases are run
                // NOTE: The type info recast here will only work when unpacking with type info that is not dynamically loaded.
                //       So this will work when we are loading our type info file, but will not do anything when using the loaded type info to unpack a data file.
                //       This should be fine, since your data file probably doesn't contain any pointers to type info, but if they do, note that this recast will not occur!
                ptr_any, done := recast_type_info(Any.{ type, ptr_ptr });
                // if !done {
                //     for context.conversion_settings.pointer_recast_procs {
                //         recast_ptr_any:, done = it.proc(.{ ptr_any, null, null }, it.data);
                //         if done { ptr_any = recast_ptr_any; break; }
                //     }
                // }
                // if ptr_any.type != type {
                //     // print("recast a pointer: % -> %\n", (*type).(*Type).*, (*ptr_any.type).(*Type).*);
                // }
                
                type_pointed_to := ptr_any.type.(*Type_Info_Pointer).pointer_to;
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
    
    #if DEBUG  array_reset_keeping_memory(*debug_trace);
    add_debug_trace("DATA");
    
    if !recurse(type, buffer, 0, *unpacked_offsets) {
        return Any.{}, false;
    }
    
    return Any.{ type, buffer.data }, true;
}


// TODO: implement for realsies after figuring out type info versioning issue

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
Pack\ _Local_Data_Pointer_Proc :: #type (ptr: Any_With_Context) -> (*void, bool);
Unpack_Local_Data_Pointer_Proc :: #type (packed_ptr: *void, pointer_to: *Type_Info) -> (*void, bool);

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
is_local_data_pointer :: inline (ptr: *void) -> bool {
    return ptr.(u64) & Packed_Pointer_Masks.LOCAL_DATA.(u64) != 0;
}

encode_local_data_pointer :: inline (ptr_data: u32, user_data: u16) -> *void {
    return (Packed_Pointer_Masks.LOCAL_DATA.(u64) | (user_data.(u64) << 32) | ptr_data.(u64)).(*void);
}

decode_local_data_pointer :: inline (ptr: *void) -> (ptr_data: u32, user_data: u16) {
    using Packed_Pointer_Masks;
    assert(is_local_data_pointer(ptr));
    return (ptr.(u64) & POINTER_DATA.(u64)).(u32), ((ptr.(u64) & USER.(u64)) >> 32).(u16);
}



#scope_module

#load "old_preload_versions.jai";
#load "type_info.jai";

#import "Basic";
#import "File";     // TODO: remove
Compiler :: #import "Compiler";     // for is_subclass_of

#import "Utils";
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
convert_type_info :Convert.User_Remap_Proc: (new_info_ptr: Any, old_info_ptr: Any, user_data: *void) -> User_Remap_Proc_Result {
    if new_info_ptr.type != xx *Type_Info then return .UNHANDLED;
    
    using _user_data := user_data.(*Convert_Type_Info_Callback_Data);
    
    // for now, we will presume that the very basic Type_Info struct in Preload.jai will never change, and we can always access the type tag.
    type_info_tag := old_info_ptr.value_pointer.(**Type_Info).*.type;
    
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
    found := array_find_where(
        generated_type_infos, 
        (it, old_info_ptr) => it.old_ptr == old_info_ptr, 
        old_info_ptr.value_pointer.(**Type_Info).*
    );
    if found {
        new_info_ptr.value_pointer.(**Type_Info).* = found.new_ptr;
        return .HANDLED;
    }
    
    // dynamically create a new type info structure for the proper type info subtype
    // then assign the pointer to that type info back to new_info_ptr
    new_info := New_Any(info_type);
    new_info_ptr.value_pointer.(**Type_Info).* = new_info.value_pointer.(*Type_Info);
    
    array_add(*generated_type_infos, .{
        old_info_ptr.value_pointer.(**Type_Info).*,
        new_info_ptr.value_pointer.(**Type_Info).*
    });
    
    _old_info_ptr := recast_type_info(old_info_ptr); 
    old_info := dereference_any_pointer(_old_info_ptr);
    
    ok := Convert.any_to_any(new_info, old_info);
    return ifx ok then .HANDLED else .ERROR;
}



DEBUG :: true;

#if DEBUG { debug_trace: [..] string; }

add_debug_trace :: (format: string, args: ..Any) #expand {
    #if DEBUG {
        array_add(*debug_trace, tprint(format, ..args));
        `defer pop(*debug_trace);
    }
} @PrintLike

