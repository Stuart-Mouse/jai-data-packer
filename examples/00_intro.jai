#import "Basic";
#import "File";
#import "Data_Packer";


Fruit :: enum {
    NONE;
    APPLE;
    PEAR;
    BANANA;
    KIWIFRUIT;
    WATERMELON;
    APRICOT;
}

Fruit_Facts :: union {
    Apple :: struct {
        flavor: float;
        pith: float;
        redness: float;
        apple_type: enum { RED_DELICIOUS; FUJI; GRANNY_SMITH; };
    }
    
    Pear :: struct {
        // I don't really know much about pears...
        flavor: float;
        pith: float;
    }
    
    Banana :: struct {
        flavor: float;
        ripeness: float;
        curvature: float;
    }
    
    apple  : Apple;
    pear   : Pear;
    banana : Banana;
}

main :: () {
    
    resolve_fruit_union_data :: Resolve_Union_By_Tag_Data.{ "fruit", type_info(Fruit), .[
        .{ xx Fruit.APPLE,  "apple"  },
        .{ xx Fruit.PEAR,   "pear"   },
        .{ xx Fruit.BANANA, "banana" },
    ]};
    
    array_add(*context.data_conversion_settings.get_union_type_procs, .{ resolve_union_by_tag, *resolve_fruit_union_data });
    
    
    {
        /*
            Imagine we have some program with the following data structure and we want to serialize it to a file.
            The structure here is very much contrived for demonstration purposes, but as you can see there are a variety of data types represented.
        */
        Test_Struct :: struct {
            numbers    : [] u8;
            floating   : float;
            text       : string;
            enumerated : enum { A; B; C; D; };
            // boolean    : bool;
            pointer    : *Test_Struct;
            fruit      : Fruit;
            flags      : enum_flags { X; Y; Z; W; };
            fruit_facts: Fruit_Facts;
        }
        
        // Creating an instance of the struct to serialize...
        test: Test_Struct = .{
            numbers    = .[ 1, 2, 3, 4, 5 ],
            floating   = 52.5,
            text       = "lorem ipsum",
            // boolean    = true,
            enumerated = .C,
            fruit      = .BANANA,
            flags      = .Y | .W,
            fruit_facts= .{ banana = .{ curvature = 0.75, ripeness = 0.5 } }
        };
        
        // And another one in order to show serialization through a pointer...
        test_other: Test_Struct = .{
            numbers    = .[ 5, 4, 3, 2, 1 ],
            floating   = 5.25,
            text       = "muspi merol",
            enumerated = .B,
            fruit      = .PEAR,
            flags      = .Z,
            fruit_facts= .{ pear = .{ pith = 0.3, flavor = 0.4 } }
        };
        
        test.pointer = *test_other;
        
        print("test:\n\t%\n", test);
        print("test.pointer:\n\t%\n", test.pointer.*);
    
        if test.fruit == {
          case .APPLE;  print("test.fruit_facts.apple: %\n", test.fruit_facts.apple);
          case .PEAR;   print("test.fruit_facts.pear: %\n", test.fruit_facts.pear);
          case .BANANA; print("test.fruit_facts.banana: %\n", test.fruit_facts.banana);
        }
        
        if test.pointer.fruit == {
          case .APPLE;  print("test.pointer.fruit_facts.apple: %\n", test.pointer.fruit_facts.apple);
          case .PEAR;   print("test.pointer.fruit_facts.pear: %\n", test.pointer.fruit_facts.pear);
          case .BANANA; print("test.pointer.fruit_facts.banana: %\n", test.pointer.fruit_facts.banana);
        }
        
        // When we pack the data and write to a file, we also specify a file path for the type info of the data.
        if !pack_file_and_type_info("test.dat", "test.ti", test) {
            print("Failed to pack data!");
            return;
        }
    }
    
    
    {
        /*
            Later, we decide to make some changes to our struct.
            We now want to store numbers in a dynamic array instead of a fixed-length array, 
                we upped the precision of 'floating' from a float to a float64,
                and we reordered the values in 'enumerated'.
            We also changed the order of the members in the struct.
            All of these changes will be handled automatically upon remapping the original file,
                however if we were to change any of the names of the members, the values would not be mapped.
            In the future I plan to add some capability to define name remappings.
        */
        Test_Struct :: struct {
            enumerated : enum { D; C; B; A; };
            numbers    : [..] int;
            text       : string;
            floating   : float64;
            pointer    : *Test_Struct;
            // boolean    : bool;
            fruit      : Fruit; // TODO: change back to [4] to demo single to array. I had to remove that to test fruit as tag for fruit facts.
            flags      : enum_flags { Y; Z; W; X; };
            fruit_facts: Fruit_Facts;
        }
        
        // When we wrote the earlier version of our structure out to file, we also saved a type info file.
        // Now, as we load the file back in we can also specify the type info file to use when reading the data file.
        test: Test_Struct;
        if !unpack_file_with_type_info("test.dat", "test.ti", test) {
            print("Failed to unpack data!");
            return;
        }
        
        // The space for test.pointer here is dynamically allocated in the unpacking routine.
        // In the future you will be able to change this behavior or set allocators to use for specific types.
        print("test:\n\t%\n", test);
        print("test.pointer:\n\t%\n", test.pointer.*);
        
        // Test for unions
        if test.fruit == {
          case .APPLE;  print("test.fruit_facts.apple: %\n", test.fruit_facts.apple);
          case .PEAR;   print("test.fruit_facts.pear: %\n", test.fruit_facts.pear);
          case .BANANA; print("test.fruit_facts.banana: %\n", test.fruit_facts.banana);
        }
        
        if test.pointer.fruit == {
          case .APPLE;  print("test.pointer.fruit_facts.apple: %\n", test.pointer.fruit_facts.apple);
          case .PEAR;   print("test.pointer.fruit_facts.pear: %\n", test.pointer.fruit_facts.pear);
          case .BANANA; print("test.pointer.fruit_facts.banana: %\n", test.pointer.fruit_facts.banana);
        }
    }
}


/*
    resolve union by tag
    
    we need to have a *void for data so that we can attach some lookup table 
        to map from tag value to union member name
    
    we can also write a proc to generate the lookup Resolve_Union_By_Tag_Data for Tagged_Union
*/
resolve_union_by_tag : Get_Union_Type_Proc : (
    dst_ti: *Type_Info, src: Any, src_parent: Any, src_member_ti: *Type_Info_Struct_Member, data: *void
) -> *Type_Info_Struct_Member {
    if dst_ti != cast(*Type_Info) Fruit_Facts  return null;
    if !src_parent.value_pointer  return null;
    if !data  return null;
    
    user_data := cast(*Resolve_Union_By_Tag_Data) data;
    
    src_ti := cast(*Type_Info_Struct) src.type;
    assert(src_ti.type == .STRUCT);
    assert(src_ti.textual_flags & .UNION == .UNION);
    
    dst_tag: s64;
    src_tag := get_member_any(src_parent, user_data.tag_member_name);
    if !remap_data(Any.{ xx user_data.tag_type, *dst_tag }, src_tag)  return null;
    
    src_member_name: string;
    for user_data.lookup {
        if it.tag_value == dst_tag {
            src_member_name = it.member_name;
            break;
        }
    }
    if !src_member_name  return null;
    
    for *src_member: src_ti.members {
        if src_member.flags & .CONSTANT  continue;
        if src_member.name == src_member_name {
            return src_member;
        }
    }
    
    return null;
}

Resolve_Union_By_Tag_Data :: struct {
    tag_member_name: string;
    tag_type: *Type_Info_Enum;
    lookup: [] struct { tag_value: s64; member_name: string; };
}

get_member_any :: (parent: Any, member_name: string) -> Any {
    assert(parent.type.type == .STRUCT);
    
    parent_ti := cast(*Type_Info_Struct) parent.type;
    
    member: *Type_Info_Struct_Member;
    for *parent_ti.members {
        if it.name == member_name {
            member = it;
            break;
        }
    }
    
    assert(member != null, "Invalid member name!");
    
    return get_member_any(parent.value_pointer, member);
}

get_member_any :: (parent_ptr: *void, member_ti: *Type_Info_Struct_Member) -> Any {
    value_pointer := parent_ptr + member_ti.offset_in_bytes;
    return Any.{ member_ti.type, value_pointer };
}

Dynamic_New_Any :: (ti: *Type_Info, initialized := true) -> Any {
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

    return Any.{ ti, memory };
}