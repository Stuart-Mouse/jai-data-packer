/*
    Load and store type info binaries to a file.
    
    This file includes a header with the Jai compiler version which was used to serialize the file, 
    so that we can continue to load old type info binaries even when type info structures change.
    
    Perhaps in the future we will use our own simplified version of type info structures so that we don't need to worry about compiler changes as much.
    The thing is, we really don't even need to store the type infos for any primitive types, so that's relatively straightforward to optimize.
    Really, I think the only type info structure that is liable to change betwee jai compiler versions is Type_Info_Struct,
    and while we could specify a certain version as always being used for the Data packer, this doesn't really benefit much
    unless we're just totally sure we don't want to use 
    
    
    Things to consider:
        Several type info structures need to reference one another, meaning...
            1. we essentially need to namespace them them and include them all.
            2. Type Info needs to be remapped recursively, unless we store our type infos smarter
        We can remove the need to store the basic primitive type infos (ints, floats, bool, void, string) by using local data pointers.
    
    Better storage method for type infos:
        What we really want is a type info library that is generated based on a metaprogram plugin
        and this library tracks changes in our struct types over time
        
        as we store type infos we give each type a unique ID.
        could be auto-increment, or for structs, we can probably just use a hash of the name
        
        
        
    
    TODO: remove this entire file and just use Data_File stuff to save type info/table files.
*/

Type_Table :: [] *Type_Info;

Type_Table_Header :: struct {
    header_version:         u64;
    jai_compiler_version:   Compiler.Version_Info;
    
    CURRENT_HEADER_VERSION :: 1;
    CURRENT_JAI_COMPILER_VERSION :: #run get_current_jai_compiler_version();
}

// pack_type_table :: (packer: *Data_Packer, type_table: Type_Table) -> bool {
//     packer: Data_Packer;
    
//     assert(0 == get_bytes(packer, size_of(Type_Table_Header)));
//     header := packer.buffer.data.(*Type_Table_Header);
//     header.header_version       = Type_Table_Header.CURRENT_HEADER_VERSION;
//     header.jai_compiler_version = Type_Table_Header.CURRENT_JAI_COMPILER_VERSION;
    
//     if !pack_data(*packer, type_table) {
//         log("Failed to pack type table!");
//         return false;
//     }
//     return true;
// }

// unpack_type_table :: (file: [] u8, base_type_info: *Type_Info = null,, allocator := temp) -> bool, Type_Table {
//     file := _file;
    
//     // if base_type info is provided, then we assume header is not present
//     header: *Type_Table_Header;
//     if !base_type_info {
//         header := file.data.(*Type_Table_Header);
//         file.data  += size_of(Type_Table_Header);
//         file.count -= size_of(Type_Table_Header);
//         base_type_info = get_base_type_info_for_jai_version(header.jai_compiler_version);
//     }
    
//     type_table, ok := unpack_data(base_type_info, *file);
//     if !ok  return false, .[];
    
//     // if we unpacked type info using old base type info, we need to remap to the new format
//     if base_type_info != xx *Type_Info {
//         // temporarily add custom remapping proc to context, then remove in defer
//         array_add(*context.conversion_settings.user_remap_procs, .{ convert_type_info, null });
//         defer context.conversion_settings.user_remap_procs.count -= 1;
        
//         // We push temp allocator for everything allocated in remapping process
//         new_table: [] *Type_Info;
//         if !Convert.any_to_any(new_table, info_any,, allocator) {
//             log("Unable to remap old type info to new type info.");
//             return null;
//         }
//         type_table = new_table;
//     }
    
//     return true, type_table;
// }

pack_type_info_with_header :: (packer: *Data_Packer, info: *Type_Info) -> bool {
    assert(0 == get_bytes(packer, size_of(Type_Table_Header)));
    header := packer.buffer.data.(*Type_Table_Header);
    header.header_version       = Type_Table_Header.CURRENT_HEADER_VERSION;
    header.jai_compiler_version = Type_Table_Header.CURRENT_JAI_COMPILER_VERSION;
    
    if !pack_data(packer, info) {
        log("Failed to pack type info!");
        return false;
    }
    return true;
}

// file contents are passed in since they need to be in memory for valid use of the type info
// the type info returned here may be a view onto the file contents or will be a remapped copy allocated with temp
unpack_type_info_with_header :: (_file: [] u8, base_type_info: *Type_Info = null) -> *Type_Info {
    file := _file;
    starting_offset: int;
    
    // if base_type info is provided, then we assume header is not present
    header: *Type_Table_Header;
    compiler_version: Compiler.Version_Info;
    
    if base_type_info == null {
        header := file.data.(*Type_Table_Header);
        starting_offset = size_of(Type_Table_Header);
        base_type_info = get_base_type_info_for_jai_version(header.jai_compiler_version);
        
        compiler_version = header.jai_compiler_version;
        log("compiler version: %", compiler_version);
    }
    
    packer: Data_Packer;
    init_packer_for_unpacking(*packer, xx file);
    defer deinit_packer(*packer);
    
    ok, info_any := unpack_data(*packer, base_type_info, starting_offset);
    if !ok  return null;
    
    info := info_any.value_pointer.(**Type_Info).*;
    
    // If we unpacked type info structures generated using an older Jai compiler version,
    // then we need to now remap those type info structures to the latest version.
    // For now, I am just allocating with temp, but it would ultimately be better to give the caller control over this.
    if base_type_info != xx *Type_Info {
        // allocations: [..] *void;
        info = convert_type_info_to_latest_structure(info, compiler_version, null,, temp);
        // log("allocations: %", allocations);
    }
    
    return info;
}

// TODO: Maybe we should also have some forwards-compatibility and remap newer type infos back into older formats if version encoded is newer than jai version we compiled with.
//       But, this is much more trouble and would probably require using the Convert module instead of a specialized remapping procedure.
get_base_type_info_for_jai_version :: (version: Compiler.Version_Info) -> *Type_Info {
    if version <  Compiler.Version_Info.{ 0, 2, 000 }  { log("Type Info generated by unsupported compiler version!"); return null; }
    if version <= Compiler.Version_Info.{ 0, 2, 011 }  { log("Using type info structures for jai compiler versions 0.2.000 - 0.2.011"); return xx *Preload_0_2_011.Type_Info; }
    if version <= Compiler.Version_Info.{ 0, 2, 024 }  { log("Using type info structures for jai compiler versions 0.2.012 - 0.2.024"); return xx *Preload_0_2_012.Type_Info; }
    if version <= Compiler.Version_Info.{ 0, 2, 030 }  { log("Using type info structures for jai compiler versions 0.2.025 - 0.2.029"); return xx *Preload_0_2_025.Type_Info; }
    
    // else use latest version
    return xx *Type_Info;
}

#scope_module

operator <  :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool { 
    if a.major >  b.major return false;
    if a.minor >  b.minor return false;
    if a.micro >= b.micro return false;
    return true; 
}
operator >  :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool { 
    if a.major <  b.major return false;
    if a.minor <  b.minor return false;
    if a.micro <= b.micro return false;
    return true; 
}
operator == :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool { return a.major == b.major && a.minor == b.minor && a.micro == b.micro; }
operator <= :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool { return a.major <= b.major && a.minor <= b.minor && a.micro <= b.micro; }
operator >= :: (a: Compiler.Version_Info, b: Compiler.Version_Info) -> bool { return a.major >= b.major && a.minor >= b.minor && a.micro >= b.micro; }

get_current_jai_compiler_version :: () -> Compiler.Version_Info #compile_time {
    version_info: Compiler.Version_Info;
    Compiler.compiler_get_version_info(*version_info);
    return version_info;
}

/*
    Previously, we were using the Convert module's any_to_any proceudre to handle the remapping more generically, 
    but with how seldom the base type info structures are modified, and by such small degrees, 
    it seems more wise to just write a fully custum procedure to handle the type info remapping.
    
    As it stands now, there is really only one significant change to type info that has occurred since I have started writing the Data Packer, 
    which is the addition of the "parameters" array in Type_Info_Struct in beta 0.2.012.
    
    NOTE: This procedure will modify type infos in place when possible, so it is critical that you only call this on dynamically loaded type infos, not those stored in read-only data by the compiler.
*/
convert_type_info_to_latest_structure :: (info: *Type_Info, jai_compiler_version: Compiler.Version_Info, allocations: *[..] *void) -> *Type_Info {
    __New :: ($T: Type) -> *T  #expand {
        new := New(T);
        if allocations then array_add(allocations, new);
        return new;
    }
    
    if info == null then return info;
    
    if info.type == {
      case .STRUCT;
        info_struct := info.(*Type_Info_Struct);
        
        // TODO: reduce code duplication here and refactor so that we can enforce that the new info struct gets fully initialized
        init_info_struct :: () #expand {
            `new_info_struct.type                    = .STRUCT;
            `new_info_struct.name                    = `old_info_struct.name;
            
            #if #exists(`old_info_struct.parameters           ) `new_info_struct.parameters              = xx,force `old_info_struct.parameters;
            #if #exists(`old_info_struct.specified_parameters ) `new_info_struct.specified_parameters    = xx,force `old_info_struct.specified_parameters;
            #if #exists(`old_info_struct.members              ) `new_info_struct.members                 = xx,force `old_info_struct.members;
            #if #exists(`old_info_struct.tagged_union_bindings) `new_info_struct.tagged_union_bindings   = xx,force `old_info_struct.tagged_union_bindings;
            
            `new_info_struct.status_flags            = xx,force `old_info_struct.status_flags;
            `new_info_struct.nontextual_flags        = xx,force `old_info_struct.nontextual_flags;
            `new_info_struct.textual_flags           = xx,force `old_info_struct.textual_flags;
            `new_info_struct.polymorph_source_struct = xx,force `old_info_struct.polymorph_source_struct;
            `new_info_struct.initializer             = `old_info_struct.initializer;
            `new_info_struct.constant_storage        = `old_info_struct.constant_storage;
            `new_info_struct.notes                   = `old_info_struct.notes;
        }
        
        // Version 0.2.012: Type_Info_Struct now has a 'parameters' array, to indicate any parameters to a struct type.
        if jai_compiler_version < Compiler.Version_Info.{ 0, 2, 012 } {
            old_info_struct := info.(*Preload_0_2_011.Type_Info_Struct);
            new_info_struct := __New(Type_Info_Struct);
            
            log("Converting Type_Info_Struct from Jai compiler version 0.2.011");
            init_info_struct();
            
            info, info_struct = new_info_struct;
        }
        // Version 0.2.025: In modules/Preload, we have added Type_Info_Tagged_Union_Binding, and Type_Info_Struct has an array of these as 'tagged_union_bindings'
        else if jai_compiler_version < Compiler.Version_Info.{ 0, 2, 025 } {
            old_info_struct := info.(*Preload_0_2_012.Type_Info_Struct);
            new_info_struct := __New(Type_Info_Struct);
            new_info_struct.type = .STRUCT;
            
            log("Converting Type_Info_Struct from Jai compiler version 0.2.024");
            init_info_struct();
            
            info, info_struct = new_info_struct;
        }
        // Version 0.2.030: Type_Info_Struct now contains an 'alignment' field, telling you the overall alignment of the struct, as determined by its members.
        else if jai_compiler_version < Compiler.Version_Info.{ 0, 2, 030 } {
            old_info_struct := info.(*Preload_0_2_025.Type_Info_Struct);
            new_info_struct := __New(Type_Info_Struct);
            new_info_struct.type = .STRUCT;
            
            log("Converting Type_Info_Struct from Jai compiler version 0.2.029");
            init_info_struct();
            
            info, info_struct = new_info_struct;
        }
        
        // NOTE: If Type_Info_Struct_Member changes in the future, we may need to do some additional work here.
        //       Most likely, we will need separate logic to remap the Type_Info_Struct_Member itself, and then remap the type info it points to.
        
        for *member_info: info_struct.parameters {
            member_info.type = convert_type_info_to_latest_structure(member_info.type, jai_compiler_version, allocations);
        }
        for *member_info: info_struct.specified_parameters {
            member_info.type = convert_type_info_to_latest_structure(member_info.type, jai_compiler_version, allocations);
        }
        for *member_info: info_struct.parameters {
            member_info.type = convert_type_info_to_latest_structure(member_info.type, jai_compiler_version, allocations);
        }
        
        if info_struct.polymorph_source_struct {
            info_struct.polymorph_source_struct = xx convert_type_info_to_latest_structure(info_struct.polymorph_source_struct, jai_compiler_version, allocations);
        }
        
      case .POINTER;
        info_pointer := info.(*Type_Info_Pointer);
        
        info_pointer.pointer_to = convert_type_info_to_latest_structure(info_pointer.pointer_to, jai_compiler_version, allocations);
        
      case .PROCEDURE;
        info_procedure := info.(*Type_Info_Procedure);
        
        for *argument_type: info_procedure.argument_types {
            argument_type.* = convert_type_info_to_latest_structure(argument_type.*, jai_compiler_version, allocations);
        }
        for *return_type: info_procedure.return_types {
            return_type.* = convert_type_info_to_latest_structure(return_type.*, jai_compiler_version, allocations);
        }
        
      case .ARRAY;
        info_array := info.(*Type_Info_Array);
        
        info_array.element_type = convert_type_info_to_latest_structure(info_array.element_type, jai_compiler_version, allocations);
        
      case .ENUM;
        // NOTE: If Type_Info_Integer changes, we will need to recurse here for internal_type.
        
      case .VARIANT;
        info_variant := info.(*Type_Info_Variant);
        
        info_variant.variant_of = convert_type_info_to_latest_structure(info_variant.variant_of, jai_compiler_version, allocations);
        
    }
    
    return info;
}
