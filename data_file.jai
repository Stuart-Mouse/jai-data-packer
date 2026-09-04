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
    
    
    TODO: Remove the need to explicitly write a table of contents and type table offset in header. 
          Instead, we should just pack the data for those array views directly into the header.
          This will reqiure altering pack_data so that we can explicitly pass a starting write offset, rather than using get_bytes.
*/

Data_File :: struct {
    using #as header:       *Data_File_Header_Base; // Header allocation includes entire file payload as well.
    // total_file_size:        int;
    allocations_to_free:    [..] *void;
}

free :: (data_file: Data_File) {
    free(data_file.header);
    if data_file.allocations_to_free {
        for data_file.allocations_to_free {
            free(it);
        }
        array_free(data_file.allocations_to_free);
    }
}

// NOTE: This header base structure will never change, but we may add to it and iterate on the Data_File_Header struct in the future.
Data_File_Header_Base :: struct {
    magic:                      u32;
    header_version:             Version;
    jai_compiler_version:       Compiler.Version_Info;
    
    // This is here for use by the user.
    // I figured 4 billion is probably enough version numbers for most use cases.
    file_version:               u32;
    
    file_timestamp:             Apollo_Time;
    
    table_of_contents_offset:   u32;
    type_table_offset:          u32;
    
    // This version enum exists primarily so that we can switch #complete on the version number.
    Version :: enum u32 #specified {
        V1, LATEST :: 1;
    }
}

// NOTE: This should always alias the latest version of the struct.
Data_File_Header :: Data_File_Header_V1;

// NOTE: When we have a need for changes to the header struct, we will need to duplicate this struct and version it.
Data_File_Header_V1 :: struct {
    using #as header_base:  Data_File_Header_Base;
    
    // TODO: I may end up deciding to move these flags into the header base, which should be fine, since these are present in V1.
    //       The only reason I am not doing so now is to avoid the unlikely case that I end up making a breaking change in terms of how the flags are specified.
    flags:  Flags;
    
    // Flags is a u64 because with flags you always want to have more.
    // The more flags your entities have, the better your game is.
    // The same is also true for data formats. More flags means more better.
    Flags :: enum_flags u64 #specified {
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
    pointer := data_file.header.(*void) + data_file.header.type_table_offset;
    return pointer.(*[]*Type_Info).*;
}

get_table_of_contents :: (data_file: Data_File) -> [] Table_Of_Contents_Entry {
    pointer := data_file.header.(*void) + data_file.header.table_of_contents_offset;
    return pointer.(*[]Table_Of_Contents_Entry).*;
}

load_data_file :: (path: string) -> (bool, Data_File) {
    file, ok := read_entire_file(path);
    if !ok {
        log("Failed to load data file: % -- File not found.", path);
        return false, .{};
    }
    
    if file.count < size_of(Data_File_Header_Base) {
        log("Failed to load data file: % -- File is too short to read header.", path);
        free(file);
        return false, .{};
    }
    
    header := cast(*Data_File_Header_Base) file.data;
    
    if header.magic != DATA_FILE_HEADER_MAGIC {
        log("Failed to load data file: % -- File magic was incorrect.", path);
        free(file);
        return false, .{};
    }
    
    if !is_valid_header_version(header.header_version) {
        log("Failed to load data file: % -- Invalid header version: %", path, header.header_version.(u32));
        free(file);
        return false, .{};
    }
    
    if file.count < get_size_of_header(header) {
        log("Failed to load data file: % -- File is too short to read full % header.", path, header.header_version);
        free(file);
        return false, .{};
    }
    
    data_file: Data_File;
    data_file.header = header;
    
    assert(header.header_version >= .V1);
    flags := header.(*Data_File_Header).flags;
    
    // log("Loading Data_File with timestamp: %", calendar_to_string(to_calendar(header.file_timestamp)));
    
    packer: Data_Packer;
    init_packer_for_unpacking(*packer, xx file);
    defer deinit_packer(*packer);
    
    type_table: [] *Type_Info;
    if (flags & .CONTAINS_TYPE_INFO) {
        base_type_info := get_base_type_info_for_jai_version(data_file.header.jai_compiler_version);
        
        type_table_type_info := Type_Info_Array.{
            type         = .ARRAY,
            runtime_size = size_of(Array_View_64),
            array_type   = .VIEW,
            element_type = base_type_info,
        };
        
        ok, type_table_any := unpack_data(*packer, *type_table_type_info, header.type_table_offset, "type_table");
        if !ok {
            log("Failed to load data file: % -- Unable to unpack type table.", path);
            return false, .{};
        }
        type_table = type_table_any.value_pointer.(*[]*Type_Info).*; // Maybe we should assert that this pointer matches what we would get from get_type_table?
        
        if base_type_info != type_info(*Type_Info) {
            for *info: type_table {
                info.* = convert_type_info_to_latest_structure(info.*, data_file.header.jai_compiler_version, *data_file.allocations_to_free);
            }
        }
    }
    
    if (flags & .CONTAINS_TABLE_OF_CONTENTS) {
        if !unpack_data(*packer, xx [] Table_Of_Contents_Entry, header.table_of_contents_offset, "table_of_contents") {
            log("Failed to load data file: % -- Unable to unpack table of contents.", path);
            return false, .{};
        }
        
        table_of_contents := get_table_of_contents(data_file);
        for toc_entry: table_of_contents {
            if !unpack_data(*packer, type_table[toc_entry.type_index], toc_entry.data_offset, toc_entry.id) {
                log("Failed to load data file: % -- Unable to unpack entry '%'.", path, toc_entry.id);
                return false, .{};
            }
        }
    } else {
        if !unpack_data(*packer, type_table[0], get_size_of_header(data_file)) {
            log("Failed to load data file: % -- Unable to unpack data file contents.", path);
            return false, .{};
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
    
    if packer.table_of_contents {
        header.flags |= .CONTAINS_TABLE_OF_CONTENTS;
        
        ok, offset := pack_data(packer, packer.table_of_contents, omit_from_toc = true);
        if !ok {
            log("Failed to write data file to path: % -- Unable to pack table of contents.", path);
            return false;
        }
        header.table_of_contents_offset = xx offset;
    }
    
    if root_type != null {
        if packer.table_of_contents {
            log("Failed to write data file to path: % -- A root_type was passed to write_data_file, but the packer contains a table of contents. This is not permitted.", path);
            return false;
        }
        
        // The root type must be the first element in the type table in case there is no table of contents.
        array_insert_at(*packer.type_table, root_type, 0);
    }
    
    if packer.type_table {
        header.flags |= .CONTAINS_TYPE_INFO;
        
        // Before writing the type table itself, we want to write whatever type infos are already contained within it individually.
        // This is because in the process of doing so, we will discover the rest of the type infos that were not already in our table, and they will get added to it.
        // Then and only then can we write the table itself.
        type_table_view: [] *Type_Info = packer.type_table;
        for type_table_view {
            if !pack_data(packer, it, omit_from_toc = true) {
                log("Failed to write data file to path: % -- Unable to pack type info.", path);
                return false; 
            }
        }
        type_table_view = packer.type_table;
        
        ok, offset := pack_data(packer, type_table_view, omit_from_toc = true);
        if !ok {
            log("Failed to write data file to path: % -- Unable to pack type table.", path);
            return false;
        }
        header.type_table_offset = xx offset;
        
        // Sanity check that writing the type table itself did not cause more type infos to be found.
        assert(packer.type_table.count == type_table_view.count, "% != %", packer.type_table.count, type_table_view.count);
    }
    
    header.file_timestamp = current_time_consensus();
    // log("Writing Data_File with timestamp: %", calendar_to_string(to_calendar(header.file_timestamp)));
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
            return true, Any.{
                type          = type_table[toc_entry.type_index],
                value_pointer = data_file.header.(*void) + toc_entry.data_offset,
            };
        }
    }
    return false, Any.{};
}


#scope_module

// #import "Print_Vars";

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



