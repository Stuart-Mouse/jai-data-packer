#import "Basic";
#import "File";
#import "Data_Packer";

main :: () {
    {
        /*
            Imagine we have some program with the following data structure and we want to serialize it to a file.
            The structure here is very much contrived for demonstration purposes, but as you can see there are a variety of data types represented.
        */
        Test_Struct :: struct {
            numbers    : [5] u8;
            floating   : float;
            text       : string;
            enumerated : enum { A; B; C; D; };
            boolean    : bool;
            pointer    : *Test_Struct;
        }
        
        // Creating an instance of the struct to serialize...
        test: Test_Struct = .{
            numbers    = .[ 1, 2, 3, 4, 5 ],
            floating   = 52.5,
            text       = "lorem ipsum",
            boolean    = true,
            enumerated = .C,
        };
        
        // And another one in order to show serialization through a pointer...
        test_other: Test_Struct = .{
            numbers    = .[ 5, 4, 3, 2, 1 ],
            floating   = 5.25,
            text       = "muspi merol",
            enumerated = .B,
        };
        
        test.pointer = *test_other;
        
        print("test:\n\t%\n", test);
        print("test.pointer:\n\t%\n", test.pointer.*);
    
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
            boolean    : bool;
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
    }
}
