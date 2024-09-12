
# Jai Data Packer

This is a library is intended to be a (relatively) simple solution for serializing and deserializing binary data in a way that is robust to changes in data structures across versions of a program.

There's really two parts to the functionality provided here, but they are both complementary:
1. packing and unpacking binary data
2. remapping data from one type to another using runtime type info

The data packing process just involves recursively navigating a data structure and copying all data into a contiguous buffer.
In the process, we also replace all pointers with integer offsets into this buffer.
When unpacking the data, we just navigate the structures as before and remap the pointers appropriately.

The data remapping process involves matching struct field names and converting data between compatible types.
Again, this process is done recursively on the provided data structures.

Putting these two things together, we can serialize or deserialize and data we want provided a Type_Info structure to guide the process, and the remapping will handle any trivial changes in the binary data format.

If you're familiar with Protobuffs, this is kind of like that, but built specifically for Jai's type system.
And thanks to most of the real work being done for us, the implementation is pretty simple.

Obviously, serializing and deserializing one's binary data in this fashion is mush slower than using handwritten procedures, but the intention here is to have a quick and dirty catchall solution to use during development.
And I'm quite confident that it's still a much more efficient solution than using a textual format like JSON or (God forbid) XML.

The basic data remapper currently only handles the most trivial cases of data changes (e.g. changing size/signedness of numeric types or size/type of an array), but I do plan to add some means of extending the remapper's capabilities in the near future.

Only the initial basic implementation is done, but there will be changes and improvement to come.
The full thing is just over 500 lines right now (representing only 3 main procedures and 6 internal helper procedures) with all the bare essential functionality, but I hope to keep it under 1000 lines even with the addition of future features.
