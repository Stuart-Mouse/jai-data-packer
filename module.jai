#import "Basic";
#import "File";
#import "Reflection";
#import "Hash_Table";

#load "remap.jai";

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
        2. write versions of remapping procedures that take Data_With_Context, so that user callbacks can be more useful
        3. consider merging remapping and unpacking
            a. main reason being, we can better handle unpacking of unions and pointer recasting
            b. will require using Data_With_Context for both unpacking and remapping procs
    
    
*/

// packs the given data and its type info and writes each to a separate file
pack_file_and_type_info :: (file_path: string, type_info_file_path: string, data: Any) -> bool {
    {
        buffer: [] u8;
        defer array_free(buffer);
        
        ok := pack_data(data.type, *buffer);
        if !ok {
            log("Failed to pack type info!\n");
            return false;
        }
        
        ok = write_entire_file(type_info_file_path, buffer.(string));
        if !ok {
            log("Failed to write type info to file!\n");
            return false;
        }
    }
    
    {
        buffer: [] u8;
        defer array_free(buffer);
        
        ok := pack_data(data, *buffer);
        if !ok {
            log("Failed to pack data!\n");
            return false;
        }
        
        ok = write_entire_file(file_path, buffer.(string));
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


// packs any data structure into a single binary blob and remaps pointers relative to start of buffer
// TODO: use a dynamic array so that we don't have to actually realloc as often as we resize the buffer
pack_data :: (data: Any, buffer: *[]u8) -> bool {
    Pointer_And_Offset :: struct { pointer: *void; offset: s64; };

    recurse :: (
        src:                Data_With_Context,
        buffer:             *[] u8, 
        write_offset:       s64, 
        packed_pointers:    *[..] Pointer_And_Offset
    ) -> bool {
        // print("Writing % at offset %\n", (*data.type).(*Type).*, write_offset);
        
        // TODO: .TYPE and .PROCEDURE can maybe be handled using special user callbacks
        if src.data.type.type == {
          case .STRUCT;
            ti_struct := src.data.type.(*Type_Info_Struct);
            
            if ti_struct.textual_flags & .UNION {
                member: *Type_Info_Struct_Member;
                for context.data_packer.conversion_settings.get_union_type_procs {
                    member = it.proc(src.data.type, src, it.data);
                    if member  break;
                }
                // If 'member' was not set, this is not necessarily treated as an error. Perhaps the union was just empty.
                if member {
                    assert(member.flags & .CONSTANT == 0);
                    // log("Resolved union member for union of type % to %", (*src.data.type).(*Type).*, (*member.type).(*Type).*);
                    member_any := Any.{ member.type, src.data.value_pointer + member.offset_in_bytes };
                    if !recurse(.{ member_any, src.data, member }, buffer, write_offset + member.offset_in_bytes, packed_pointers) {
                        return false;
                    }
                }
            }
            
            last_member_offset := -1;
            for *member: ti_struct.members {
                if member.flags & .CONSTANT  continue;
                // ignoring #place members. Wish there were a better way to do this.
                if member.offset_in_bytes < last_member_offset  break; 
                last_member_offset = member.offset_in_bytes;
                
                add_debug_trace(".%", member.name);
                member_any := Any.{ member.type, src.data.value_pointer + member.offset_in_bytes };
                if !recurse(.{ member_any, src.data, member }, buffer, write_offset + member.offset_in_bytes, packed_pointers) {
                    return false;
                }
            }
            
          case .ARRAY;
            data_write_offset: s64   = ---;
            array_data:        *void = ---;
            array_count:       int   = ---;
            
            ti_array := src.data.type.(*Type_Info_Array);
            if ti_array.array_type != .FIXED {
                raw_array        := src.data.value_pointer.(*Resizable_Array).*;
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
                memcpy(*buffer.data[write_offset], *raw_array, src.data.type.runtime_size);   // this will work for both resizable and slice because we use src.data.type.runtime_size
            } else {
                array_data        = src.data.value_pointer;
                array_count       = ti_array.array_count;
                data_write_offset = write_offset;
            }
            
            elem_any := Any.{ ti_array.element_type, array_data };
            for 0..array_count-1 {
                add_debug_trace("[%]", it);
                if !recurse(.{ elem_any, src.data, null }, buffer, data_write_offset, packed_pointers) {
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
            memcpy(*buffer.data[write_offset], src.data.value_pointer, src.data.type.runtime_size);
            
          case .STRING;
            str := src.data.value_pointer.(*string).*;
            data_write_offset := buffer.count;
            
            array_resize(buffer, buffer.count + str.count);
            memcpy(*buffer.data[data_write_offset], str.data, str.count);
            
            str.data = data_write_offset.(*u8);
            memcpy(*buffer.data[write_offset], *str, size_of(string));
            
          case .POINTER;
            #assert(size_of(*void) == size_of(s64));
            raw_pointer := src.data.value_pointer.(**void).*;
            if raw_pointer == null {
                memset(*buffer.data[write_offset], 0, size_of(*void));
                return true;
            }
            
            // maybe recast pointer to more specific type
            ptr_any, done := recast_type_info(src.data);
            if !done {
                for context.data_packer.conversion_settings.pointer_recast_procs {
                    recast_ptr_any:, done = it.proc(.{ ptr_any, src.parent, src.struct_member_info }, it.data);
                    if done { ptr_any = recast_ptr_any; break; }
                }
            }
            if ptr_any.type != src.data.type {
                // print("recast a pointer: % -> %\n", (*src.data.type).(*Type).*, (*ptr_any.type).(*Type).*);
            }
            
            // ENCODE LOCAL DATA POINTERS
            // pack_local_ptr := context.data_packer.pack_local_data_pointer;
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
                if !recurse(.{ derefed_any, src.parent, src.struct_member_info }, buffer, ptr_offset, packed_pointers) {
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
    
    array_resize(buffer, data.type.runtime_size);
    if !recurse(.{ data = data }, buffer, 0, *packed_pointers) {
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
            
            last_member_offset := -1;
            for member: ti_struct.members {
                if member.flags & .CONSTANT  continue;
                // ignoring #place members. Wish there were a better way to do this.
                if member.offset_in_bytes < last_member_offset  break; 
                last_member_offset = member.offset_in_bytes;
                
                add_debug_trace(".%", member.name);
                if !recurse(member.type, buffer, read_offset + member.offset_in_bytes, unpacked_offsets) {
                    print("Error while unpacking data for struct member.\n");
                    return false;
                }
            }
            
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
                
                assert(raw_array.data.(u64) >= 0 && raw_array.data.(u64) < buffer.count.(u64));
                
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
                //     unpack_local_ptr := context.data_packer.unpack_local_data_pointer;
                //     if unpack_local_ptr == null {
                //         log("Error: encountered a local data pointer, but context.data_packer.unpack_local_data_pointer was null.");
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
                if !done {
                    for context.data_packer.conversion_settings.pointer_recast_procs {
                        recast_ptr_any:, done = it.proc(.{ ptr_any, null, null }, it.data);
                        if done { ptr_any = recast_ptr_any; break; }
                    }
                }
                if ptr_any.type != type {
                    // print("recast a pointer: % -> %\n", (*type).(*Type).*, (*ptr_any.type).(*Type).*);
                }
                
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

/*
    NOTE: This has absolutely nothing to do with the implicit context system.
    Throughout the process of packing/unpacking/remapping data, we often want to know more about a piece of data than just the type.
    So in addition to the Any for a piece of data, we pass around some additional contextual information.
    We pass a Data_With_Context to the callback procedures for recasting pointers and resolving union types. 
*/
Data_With_Context :: struct {
    data:                 Any;
    parent:               Any;                        // if data is a struct member or array element, this points to the struct or array.
    struct_member_info:   *Type_Info_Struct_Member;   // if data is a struct member, this is the info for that. may be null.
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
Pack\ _Local_Data_Pointer_Proc :: #type (ptr: Data_With_Context) -> (*void, bool);
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


#if DEBUG  debug_trace: [..] string;

add_debug_trace :: (format: string, args: ..Any) #expand {
    #if DEBUG {
        array_add(*debug_trace, tprint(format, ..args));
        `defer pop(*debug_trace);
    }
} @PrintLike

#scope_module

DEBUG :: false;

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

