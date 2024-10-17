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
    
    ti_any:, ok = unpack_data(
        type_info(*Type_Info), 
        cast(*[]u8) *ti_file
    );
    if !ok  return false;
    
    data_file:, ok = read_entire_file(file_path);
    if !ok  return false;
    defer free(data_file);
    
    data_any:, ok = unpack_data(
        (cast(**Type_Info) ti_any.value_pointer).*,
        cast(*[]u8) *data_file
    );
    if !ok  return false;
    
    return remap_data(data, data_any);
}


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
    
    array_resize(*buffer, data.type.runtime_size);
    if !recurse(data, *buffer, 0, *pointer_map) {
        free(buffer.data);
        return .[], false;
    }
    
    return buffer, true;
}

// converts pointers in binary blob back into absolute pointers and returns an Any of the base data
unpack_data :: (type: *Type_Info, buffer: *[] u8) -> Any, bool {
    recurse :: (type: *Type_Info, buffer: *[] u8, offset: s64) -> bool {
        // print("Unpacking data of type % at offset %\n", type.*, offset);
        
        if type.type == {
          case .STRUCT;
            ti_struct := cast(*Type_Info_Struct) type;
            for ti_struct.members {
                if !recurse(it.type, buffer, offset + it.offset_in_bytes) {
                    print("Error while unpacking data for struct member.\n");
                    return false;
                }
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
                if !recurse(ti_array.element_type, buffer, data_offset) {
                    print("Error while packing data for array.\n");
                    return false;
                }
                data_offset += ti_array.element_type.runtime_size;
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
                derefed_offset := cast(s64) ptr_ptr.*;
                if cast(u64) derefed_offset >= cast(u64) buffer.data {
                    // print("pointer was already adjusted...\n");
                    return true;
                }
                
                ptr_ptr.* = xx (buffer.data + derefed_offset);
                // print("offset % -> ptr %\n", derefed_offset, ptr_ptr.*);
                
                _data := recast_type_info(Any.{ type, ptr_ptr });
                if type != _data.type {
                    // print("recast *Type_Info to %\n", (cast(*Type)*_data.type).*);
                }
                
                ti_derefed := (cast(*Type_Info_Pointer)_data.type).pointer_to;
                if !recurse(ti_derefed, buffer, derefed_offset) {
                    print("Error while packing data for array.\n");
                    return false;
                }
            }
            
        }
        return true;
    }
    
    if !recurse(type, buffer, 0) {
        return Any.{}, false;
    }
    
    return Any.{ type, *buffer.data[0] }, true;
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

array_reserve_nonpoly :: (array: *Resizable_Array, desired_items: s64, elem_size: s64) {
    if desired_items <= array.allocated return;
    
    if !array.allocator.proc  remember_allocators(array);
    
    array.data = realloc(array.data, desired_items * elem_size, array.allocated * elem_size,, array.allocator);
    assert(array.data != null); // The program will die if we couldn't get memory. We can think about an alternative strategy, but it's hard to know what would be reasonable.
    
    array.allocated = desired_items;
}
