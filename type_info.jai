/*
    Load and store type info binaries to a file.
    
    This file includes a header with the Jai compiler version which was used to serialize the file, 
    so that we can continue to load old type info binaries even when type info structures change.
    
    Perhaps in the future we will use our own simplified version of type info structures so that we don't need to worry about compiler changes as much.
*/




Type_Info_File_Header :: struct {
    header_version:         u64;
    jai_compiler_version:   Compiler.Version_Info;
    
    CURRENT_HEADER_VERSION :: 1;
}

pack_type_info_with_header :: (info: *Type_Info, buffer: *[] u8) -> bool {
    array_resize(buffer, size_of(Type_Info_File_Header));
    header := buffer.data.(*Type_Info_File_Header);
    header.header_version = Type_Info_File_Header.CURRENT_HEADER_VERSION;
    Compiler.compiler_get_version_info(*header.jai_compiler_version);
    
    if !pack_data(info, buffer) {
        log("Failed to pack type info!");
        return false;
    }
    
    return true;
}

// file contents are passed in since they need to be in memory for valid use of the type info
// the type info returned here may be a view onto the file contents or will be a remapped copy allocated with temp
unpack_type_info_with_header :: (_file: [] u8, base_type_info: *Type_Info = null) -> *Type_Info {
    file := _file;
    
    // if base_type info is provided, then we assume header is not present
    header: *Type_Info_File_Header;
    if !base_type_info {
        header := file.data.(*Type_Info_File_Header);
        file = array_view(file, size_of(Type_Info_File_Header));
        base_type_info = get_base_type_info_for_jai_version(header.jai_compiler_version);
    }
    
    info_any, ok := unpack_data(base_type_info, *file);
    if !ok  return null;
    
    // if we unpacked type info using old base type info, we need to remap to the new format
    if base_type_info != xx *Type_Info {
        // temporarily add custom remapping proc to context, then remove in defer
        callback_data: Convert_Type_Info_Callback_Data;
        array_add(*context.conversion_settings.user_remap_procs, .{ convert_type_info, *callback_data });
        defer context.conversion_settings.user_remap_procs.count -= 1;
        
        // We push temp allocator for everything allocated in remapping process
        new_info: *Type_Info;
        if !Convert.any_to_any(new_info, info_any,, temp) {
            log("Unable to remap old type info to new type info.");
            return null;
        }
        info_any = new_info;
        
        // TODO: we should use some deep compare proc to validate that our type infos were converted correctly
    }
    
    return info_any.value_pointer.(**Type_Info).*;
}


get_base_type_info_for_jai_version :: (version: Compiler.Version_Info) -> *Type_Info {
    operator < :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool {
        return a.major < b.major || a.minor < b.minor || a.micro < b.micro;
    }
    operator == :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool {
        return a.major == b.major && a.minor == b.minor && a.micro == b.micro;
    }
    operator <= :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool {
        return a < b || a == b;
    }
    
    // current_version := Compiler.compiler_get_version_info();
    
    if version <= Compiler.Version_Info.{ 0, 2, 012 }  return xx *Preload_0_2_012.Type_Info;
    
    // else use latest version
    return xx *Type_Info;
}
