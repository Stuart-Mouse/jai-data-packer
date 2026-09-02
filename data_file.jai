/*
    Data file layout (braces indicates conditional inclusion)
    
    header
    binary data
    [table of contents]
    [type table]
    [type info structures]
    
    type table would not really be necessary if it were not for the need to remap type infos generated for older compiler versions
    but alas, it is necessary at the moment...
    
    NOTE: In the case that you elect not to include a table of contents, but do include type info, the root type info will always be the type at index 0.
*/

// This is the structure we return to the user by pointer when we load a data file.
// The file contents will be present directly after the header.
// Having this be a distinct type means we can more easily define the user interface around it.
// NOTE: I may need to turn this into a struct later if we end up altering the header format, since in that case, we would probably want to automatically remap to the latest header format...
//       Also, we will actually want to rectify a lot of the file contents (pointers in the embedded type info and table of contents) before handing the Data_File back to the user...
Data_File :: struct {
    using #as header:       *Data_File_Header_Base; // Header allocation includes entire file payload as well.
    
    // TODO: after refactoring how type info remapping is done, we should instead modify the typ einfo table in place and only use this additional array for type_infos_to_free
    remapped_type_infos:    [] *Type_Info;          // All of these need to be freed individually if present.
}

free :: (data_file: Data_File) {
    free(data_file.header);
    if data_file.remapped_type_infos {
        for data_file.remapped_type_infos {
            free(it);
        }
        array_free(data_file.remapped_type_infos);
    }
}

// NOTE: This header base structure will never change, but we may add to it and iterate on the Data_File_Header struct in the future.
Data_File_Header_Base :: struct {
    magic:                      u32;
    header_version:             Version;
    jai_compiler_version:       Compiler.Version_Info;
    file_version:               u32;
    
    table_of_contents_offset:   u32;
    type_table_offset:          u32;
    
    // This version enum exists primarily so that we can switch #complete on the version number.
    Version :: enum u32 #specified {
        V1, LATEST :: 1;
    }
}

Data_File_Header :: Data_File_Header_V1;

// NOTE: When we have a need for changes to the header struct, we will need to duplicate this struct and version it.
Data_File_Header_V1 :: struct {
    using #as header_base:  Data_File_Header_Base;
    
    // TODO: I may end up deciding to move these flags into the header base, which should be fine, since these are present in V1.
    //       The only reason I am not doing so now is to avoid the unlikely case that I end up making a breaking change in terms of how the flags are specified.
    flags:  Flags;
    
    Flags :: enum_flags u32 #specified {
        CONTAINS_TYPE_INFO              :: 1 << 0;
        CONTAINS_TABLE_OF_CONTENTS      :: 1 << 1;
        
        NONE :: 0;
    }
}

data_file_header_versions : [Data_File_Header_Base.Version.LATEST+1] *Type_Info : .[
    type_info(Data_File_Header_Base),
    type_info(Data_File_Header_V1),
];

is_valid_header_version :: (version: Data_File_Header_Base.Version) -> bool {
    return version >= 1 && version <= Data_File_Header_Base.Version.LATEST;
}

get_size_of_header :: (header: *Data_File_Header_Base) -> int {
    if !is_valid_header_version(header.header_version) {
        assert(false, "Invalid header version: %", header.header_version);
    }
    return data_file_header_versions[header.header_version].runtime_size;
}

get_pointer_to_data_blob :: (data_file: Data_File) -> *void {
    return data_file.(*void) + get_size_of_header(data_file);
}

get_type_table :: (data_file: Data_File) -> [] *Type_Info {
    if data_file.remapped_type_infos  return data_file.remapped_type_infos;
    
    pointer := data_file.header.(*void) + data_file.header.type_table_offset;
    return pointer.(*[]*Type_Info).*;
}

get_table_of_contents :: (data_file: Data_File) -> [] Table_Of_Contents_Entry {
    pointer := data_file.header.(*void) + data_file.header.table_of_contents_offset;
    return pointer.(*[]Table_Of_Contents_Entry).*;
}

// NOTE: Returns null on failure.
load_data_file :: (path: string) -> (bool, Data_File) {
    file, ok := read_entire_file(path);
    if !ok {
        log("Failed to load data file from path: % -- File not found.", path);
        return false, .{};
    }
    
    if file.count < size_of(Data_File_Header_Base) {
        log("Failed to load data file from path: % -- File is too short to read header.", path);
        free(file);
        return false, .{};
    }
    
    header := cast(*Data_File_Header_Base) file.data;
    
    if header.magic != DATA_FILE_HEADER_MAGIC {
        log("Failed to load data file from path: % -- File magic was incorrect.", path);
        free(file);
        return false, .{};
    }
    
    if !is_valid_header_version(header.header_version) {
        log("Failed to load data file from path: % -- Invalid header version: %", path, header.header_version.(u32));
        free(file);
        return false, .{};
    }
    
    if file.count < get_size_of_header(header) {
        log("Failed to load data file from path: % -- File is too short to read full % header.", path, header.header_version);
        free(file);
        return false, .{};
    }
    
    data_file: Data_File;
    data_file.header = header;
    
    // TODO: unpack type info structures
    
    assert(header.header_version >= .V1);
    flags := header.(*Data_File_Header).flags;
    
    type_table: [] *Type_Info;
    if (flags & .CONTAINS_TYPE_INFO) {
        // type_table := get_type_table(data_file);
        
        log("header.type_table_offset: %", header.type_table_offset);
        _, ok := unpack_data(xx [] *Type_Info, xx file, header.type_table_offset, "type_table");
        
        // TODO: Rectify type infos to use latest structure if need be.
        //       I'd like to actually write a conversion procedure that doesn't use the Convert module this time.
        //       Until then, just assert that we are using the latest version.
        base_type_info := get_base_type_info_for_jai_version(data_file.header.jai_compiler_version);
        if base_type_info != type_info(*Type_Info) {
            log("Failed to load data file from path: % -- Failed while trying to unpack type table.", path);
            free(file);
            return false, .{};
        }
        
        type_table = get_type_table(data_file);
    }
    
    log("type_table [%]:", type_table.count);
    for type_table {
        log("\t%", (*it).(*Type).*);
    }
    
    if (flags & .CONTAINS_TABLE_OF_CONTENTS) {
        log("header.table_of_contents_offset: %", header.table_of_contents_offset);
        _, ok := unpack_data(xx [] Table_Of_Contents_Entry, xx file, header.table_of_contents_offset, "table_of_contents");
        
        log("table of contents:");
        table_of_contents := get_table_of_contents(data_file);
        for toc_entry: table_of_contents {
            type := type_table[toc_entry.type_index];
            // _, ok := unpack_data(type, xx file, toc_entry.data_offset, toc_entry.id);
            
            log("\t%: % @ %", toc_entry.id, (*type).(*Type).*, toc_entry.data_offset);
        }
    }
    
    return true, data_file;
}

create_packer_for_data_file :: (file_version: u32 = 0) -> Data_Packer {
    packer: Data_Packer;
    
    // TODO: maybe just make a standard header initializer proc.
    header_offset := get_bytes(*packer, size_of(Data_File_Header));
    
    header := (packer.buffer.data + header_offset).(*Data_File_Header);
    header.magic                = DATA_FILE_HEADER_MAGIC;
    header.header_version       = Data_File_Header.Version.LATEST;
    header.jai_compiler_version = #run get_current_jai_compiler_version();
    header.file_version         = file_version;
    
    return packer;
}

// TODO: Remove the need to pass root type explicitly here. This is dumb, but there's not currently a better way...
write_data_file :: (packer: *Data_Packer, path: string, root_type: *Type_Info = null) -> bool {
    header := packer.buffer.data.(*Data_File_Header).*;
    assert(header.magic == DATA_FILE_HEADER_MAGIC, "Unable to write data file from packer that was not initialized with a valid data file header!");
    // Maybe should also check version is latest?
    
    // if packer.flags & .SHOULD_WRITE_TABLE_OF_CONTENTS {
    if packer.table_of_contents {
        header.flags |= .CONTAINS_TABLE_OF_CONTENTS;
        
        ok, offset := pack_data(packer, packer.table_of_contents, omit_from_toc = true);
        // TODO: if !ok
        header.table_of_contents_offset = xx offset;
    }
    
    // if include_type_info {
        header.flags |= .CONTAINS_TYPE_INFO;
        
        // TODO: handle root type thing
        
        // Before writing the type table itself, we want to write whatever type infos are already contained within it individually.
        // This is because in the process of doing so, we will discover the rest of the type infos that were not already in our table, and they will get added to it.
        // Then, and only then, can we write the table itself.
        
        type_table_view: [] *Type_Info = packer.type_table;
        for type_table_view {
            ok := pack_data(packer, it, omit_from_toc = true);
            // TODO: if !ok
        }
        type_table_view = packer.type_table;
        
        ok, offset := pack_data(packer, type_table_view, omit_from_toc = true);
        // TODO: if !ok
        header.type_table_offset = xx offset;
        
        // Sanity check that writing the table itself did not cause more type infos to be found.
        assert(packer.type_table.count == type_table_view.count, "% != %", packer.type_table.count, type_table_view.count);
    // }
    
    packer.buffer.data.(*Data_File_Header).* = header;
    
    write_entire_file(path, packer.buffer.(string));
    deinit_packer(packer);
    
    return true;
}


Table_Of_Contents_Entry :: struct {
    id:             string;
    type_index:     u32;
    data_offset:    u32;
}

get_content_as_any :: (data_file: Data_File, id := "") -> bool, Any {
    flags := data_file.header.(*Data_File_Header).flags;
    
    if !(flags & .CONTAINS_TYPE_INFO) {
        log("Error: get_content_as_any can only be called on a data file which contains type info.");
        return false, Any.{};
    }
    
    if !id {
        if flags & .CONTAINS_TABLE_OF_CONTENTS {
            log("Error: id is required in call to get_content_as_any when the data file contains a table of contents.");
            return false, Any.{};
        }
        
        type_table := get_type_table(data_file);
        
        return true, Any.{
            type          = type_table[0],
            value_pointer = data_file.header.(*void) + get_size_of_header(data_file),
        };
    }
    
    type_table        := get_type_table(data_file);
    table_of_contents := get_table_of_contents(data_file);
    for toc_entry: table_of_contents {
        if toc_entry.id == id {
            print_vars(toc_entry.id, toc_entry.data_offset, toc_entry.type_index);
            return true, Any.{
                type          = type_table[toc_entry.type_index],
                value_pointer = data_file.header.(*void) + toc_entry.data_offset,
            };
        }
    }
    return false, Any.{};
}

#import "Print_Vars";





#scope_module

DATA_FILE_HEADER_MAGIC       :: 0xDA7A_DA7A;
CURRENT_JAI_COMPILER_VERSION :: #run get_current_jai_compiler_version();

// write_array_count_and_values :: (buffer: [] u8, buffer_offset: int, source: [] $T, $Count_Type: Type = int) -> bool {
//     total_write_size := size_of(Count_Type) + size_of(T) * source.count;
//     if buffer.count < buffer_offset + total_write_size then return false;
    
//     write_pointer := buffer.data + buffer_offset;
//     write_pointer.(*Count_Type).* = packer.table_of_contents.count.(Count_Type);
//     write_pointer += size_of(Count_Type);
    
//     for source {
//         write_pointer.(*T).* = it;
//         write_pointer += size_of(T);
//     }
    
//     return true;
// }

// read_array_count_and_values :: (buffer: [] u8, buffer_offset: int, $T: Type, $Count_Type: Type = int) -> (bool, [] T) {
//     total_read_size := size_of(Count_Type) + size_of(T) * source.count;
//     if buffer.count < buffer_offset + total_read_size then return false, .[];
    
//     array: [] T = ---;
    
//     read_pointer := buffer.data + buffer_offset;
//     array.count   = read_pointer.(*Count_Type).*.(int);
//     read_pointer += size_of(Count_Type);
    
//     array.data = read_pointer;
    
//     return true, array;
// }



