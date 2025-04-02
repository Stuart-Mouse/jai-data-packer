
Conversion_Types :: enum_flags u64 {
    UNKNOWN_CONVERSION     :: 0;
    NO_CONVERSION_REQUIRED :: 1;
    
    INT_TO_INT;
    INT_NARROWING;
    FLOAT_TO_FLOAT;
    FLOAT_NARROWING;
    
    INT_TO_FLOAT;
    FLOAT_TO_INT;
    
    ENUM_TO_INT;
    INT_TO_ENUM;
    ENUM_TO_FLOAT;
    FLOAT_TO_ENUM;
    
    // Remapping enum
    ENUM_BY_NAME;
    ENUM_BY_VALUE;
    ENUM_TO_FLAGS;          // included in enum, but hardcoded as unsupported for now
    
    // To/from bool?
    
    // STRING_TO_CSTRING;      // TODO: allocates
    // STRING_TO_INT;
    // STRING_TO_ENUM;
    // STRING_TO_FLOAT;
    
    // TODO: maybe we want to reduce the number of permutations for arrays here?
    RESIZABLE_ARRAY_TO_VIEW;
    FIXED_ARRAY_TO_VIEW;
    FIXED_ARRAY_TO_RESIZABLE; // TODO: allocates
    WIDEN_FIXED_ARRAY;
    TRUNCATE_FIXED_ARRAY;
    SINGLE_TO_ARRAY;        // allows treating a single instance of T as a [1] T   (NOTE: this will only work if VIEW_TO_FIXED_ARRAY is also enabled!)
    VIEW_TO_FIXED_ARRAY;    // also applies to resizable
    FIXED_ARRAY_OR_VIEW_TO_RESIZABLE;   // invloves setting allocators somehow...
    
    STRING_TO_FIXED_ARRAY;
    STRING_TO_VIEW;
    STRING_TO_RESIZABLE;
    
    COPY_VIEW; // copy the actual underlying data pointed to by array views, so that dst view owns the underlying data.
    
    
    REMAP_STRUCT;
    REMAP_UNION;    // currently hardcoded as unsupported
    REMAP_THROUGH_POINTER;
    RECAST_POINTER;
    
    ALL :: 0xFFFF_FFFF_FFFF_FFFF;
}

Conversion_Settings :: struct {
    allowed_conversions:    Conversion_Types;
    float_to_int_rounding:  enum { TRUNCATE; FLOOR; CEIL; NEAREST; };
    pointer_recast_procs:   [..] struct { proc: Pointer_Recast_Proc; data: *void; };
    get_union_type_procs:   [..] struct { proc: Resolve_Union_Proc;  data: *void; };
    
    // TODO: probably add some more in-depth rules for struct remapping.
    //       and probably allow overloading these on a per-struct basis
    //       maybe we check for certain notes on the struct/members?
    //       we could use notes for some aspects of arrays (views owning data, allocator for resizable arrays) idk
    //       better than notes would actually be just using the member data LUT thing I do in GON parser. (though this is still cope for not having structured notes)
}

#add_context data_packer: struct {
    conversion_settings: *Conversion_Settings = *default_conversion_settings; // by pointer so that user can switch out conversion settings trivially
};

// the Any's passed in and out must be pointers
// returns true if the type has been recast, false if not
// this is only for casting down to a more specific type (e.g.: casting a *Type_Info down to a *Type_Info_Enum)
Pointer_Recast_Proc :: #type (ptr: Data_With_Context, user_data: *void) -> (Any, bool);

// Union types are resolved by returning the type info struct member for the union member that is valid.
// The union_ti parameter is used during remapping to pass the type info for the dst union's type info, 
//     since we usually want to match on this rather than on the src type (which is probably dynamically loaded type info).
Resolve_Union_Proc :: #type (union_ti: *Type_Info, src: Data_With_Context, user_data: *void) -> *Type_Info_Struct_Member;


// TODO: generalized remap callback that will completely override remapping for a given dst type
//       peraps that was even th emore wise/simple way to go for unions, but whatever
//       if we did that generally for unions, we would have to always pass src_parent to remap_data

// TODO: consider also casting up to more general type? This is more of something we can do in a LUT I think.

// TODO: also consider what to do about procedure pointers
//       maybe we can give user a way to store procedures as a string or enum value in data packer, then deconvert on parse?
//       or we can use another flag to denote proc pointer in Packed_Pointer_Flags and let the user map other 32 bits to a proc pointer
//       we may not need to use a bitflag in in packed pointer, since we can already differentiate pointer from procedure in type info.
//       but maybe that's just easier anyhow?

is_allowed :: inline (conversion_type: Conversion_Types) -> bool { 
    return context.data_packer.conversion_settings.allowed_conversions & conversion_type == conversion_type;
}

log_disallowed_conversion :: inline (conversion: Conversion_Types, proc_name: string, loc := #caller_location) {
    log("Error: disallowed conversion % in % (line: %)", conversion, proc_name, loc.line_number);
}

log_unsupported_conversion :: inline (conversion: Conversion_Types, proc_name: string, loc := #caller_location) {
    log("Error: unsupported conversion % in % (line: %)", conversion, proc_name, loc.line_number);
}

default_conversion_settings := DEFAULT_CONVERSION_SETTINGS;
DEFAULT_CONVERSION_SETTINGS :: Conversion_Settings.{
    allowed_conversions   = .ALL,
    float_to_int_rounding = .TRUNCATE,
};


// TODO: could improve slightly by making a version of remap_data which is bakeable on dst type.
//       that way, we could remove the extra function calls and switch on dst type.
remap_to :: inline ($T: Type, src: Any) -> (T, bool) {
    result: T;
    ok := remap_data(result, src);
    return result, ok;
}


// The most general remapping procedure. 
// Handles any dst and src types.
remap_data :: (dst: Any, src: Any) -> bool {
    // for now we are not requiring that src subtype and dst subtype match up top
    // for the cases where this matters, we check those individually
    
    // print("remapping % -> %\n", src.type.type, dst.type.type);
    
    // TODO: handling for type info variant 
    // TODO: maybe move handling for pointers up top 
    
    if dst.type.type == {
      case .STRING;
        if src.type.type == .STRING {
            // TODO: we would like to have an option as to whether this should copy
            dst.value_pointer.(*string).* = copy_string(src.value_pointer.(*string).*);
            return true;
        }
        // array-to-string conversion
        // TODO: add conversion settings for this
        if src.type.type == .ARRAY {
            ti_array := src.type.(*Type_Info_Array);
            // cannot just compare to type_info(u8), since src is probably dynamically loaded
            // so instead we assume that any type with runtime size of 1 is probably u8... 
            if ti_array.element_type.runtime_size == 1  return false; 
            if ti_array.array_type == .FIXED {
                dst_string := dst.value_pointer.(*string);
                memcpy(dst_string.data, src.value_pointer, ti_array.array_count);
                dst_string.count = ti_array.array_count;
            } else {
                // TODO: we would like to have an option as to whether this should copy
                dst.value_pointer.(*string).* = copy_string(src.value_pointer.(*string).*);
            }
            return true;
        }
        return false;
        
      case .BOOL;
        return any_to_bool(dst, src);
        
      case .INTEGER;
        return remap_int(dst, src);
        
      case .FLOAT;
        return remap_float(dst, src);
        
      case .STRUCT;
        // currently, we only do struct -> struct
        // maybe in the future we will allow other types to coerce to structs
        if src.type.type != dst.type.type  return false; 
        return remap_struct(dst, src);
        
      case .ENUM;
        return remap_enum(dst, src);
        
      case .ARRAY;
        return remap_array(dst, src);
        
      case .POINTER;
        // two methods of copying pointers:
        //   1. copy the pointer itself (requires that the src and dst type match, or that they can cast to the same base type)
        //   2. copy and remap the data through the pointer (requires allocating space for dst type)
        
        // TODO: implement parameter for pointer handling mode, or something like io data
        
        // Type 1: shallow copy of pointer itself
        
        // TODO: make this more powerful by allowing recasting of pointers to common type.
        // e.g.: dst is *Type_Info and src is *Type_Info_Struct, should be allowed
        
        // if src.type == dst.type {
        //     (cast(**void)dst.value_pointer).* = (cast(**void)src.value_pointer).*;
        // }
        
        // Type 2: deep copy with data remapping
        
        // TODO: add option to configure allocator to use for a given type
        
        if src.value_pointer == null  return true;
        
        src_derefed := deref_any_pointer(src);
        if src_derefed.value_pointer == null  return true;
        
        dst_derefed := deref_any_pointer(dst);
        if dst_derefed.value_pointer == null {
            dst_derefed.value_pointer = Dynamic_New(dst_derefed.type);
            dst.value_pointer.(**void).* = dst_derefed.value_pointer;
        }
        
        // if this fails, we should deallocate the dynamic_new'd item
        return remap_data(dst_derefed, src_derefed);
        
      // case .VARIANT;
    }
    
    return true;
}

remap_struct :: (dst: Any, src: Any) -> bool {
    assert(src.type.type == .STRUCT);
    assert(dst.type.type == .STRUCT);
    
    if !is_allowed(.REMAP_STRUCT) {
        log_unsupported_conversion(.REMAP_STRUCT, "remap_struct");
        return false;
    }
    
    dst_ti := dst.type.(*Type_Info_Struct);
    src_ti := src.type.(*Type_Info_Struct);
    
    /*
        NOTE: ignoring #place struct members
        
        If we do not ignore #place members, we will end up doing a lot of duplicate work.
        
        I am not sure if we will ever have very nice handling for #place struct members, since they are highly problematic to remapping.
        Generally, most #place members are used to provide an alternative way of accessing the data held in a struct, for example:
            'xy' and 'yz' members in a Vector3
            'floats' and 'coefs' members in a mat4
        These are essentially 0-cost getters, or an alternative interface to the same underlying data.
        
        This is unlike a union, because a union is typically storing two different pieces of data in the same memory space.
        I am sure there is probably some niche use case for #place where the members actually serve to encode unique data, but since it is uncommon, I have not really considered how to make affordances for that use case.
    */
    
    // TODO: once we have union working, we can go back to using <= in the below #place checks
    
    // remap elements by name
    last_dst_member_offset := -1;
    for dst_member: dst_ti.members {
        if dst_member.flags & .CONSTANT  continue;
        if dst_member.offset_in_bytes < last_dst_member_offset  {
            break; // ignoring #place members. Wish there were a better way to do this.
        }
        last_dst_member_offset = dst_member.offset_in_bytes;
        
        // TODO: I am probably not handling the case where a using is on a union, but aaaaaahhhhh 
        
        // use of get_field here should probably not result in any unintentional redundant copying of fields I think?
        // but maybe if we have some memory leak show up at some point, this is a place to keep in mind...
        src_member := get_field(src_ti, dst_member.name);
        if src_member == null {
            // I'm not sure if this could have unintended side-effects,
            // but the idea here is that if we can't find a match for a member that has a using on it, 
            // then we will fallback to trying to look for the members of the using'd member in the top level of src struct
            // this should allow the remapper to catch cases where you factor out some member into a another struct and then 'using' that new struct in the old struct 
            if dst_member.flags & .USING {
                print("remapping src to using'd member % (%)\n", dst_member.name, as_type(dst_member.type));
            
                dst_member_any := Any.{ dst_member.type, dst.value_pointer + dst_member.offset_in_bytes };
                if !remap_data(dst_member_any, src)  {
                    log("Error: failed while remapping struct member %!", dst_member.name);
                    return false;
                }
            }
            continue;
        }
        if src_member.flags & .CONSTANT  continue;
        
        // print("remapping member % to % (%)\n", src_member.name, dst_member.name, as_type(dst_member.type));
        
        dst_member_any := Any.{ dst_member.type, dst.value_pointer + dst_member.offset_in_bytes };
        src_member_any := Any.{ src_member.type, src.value_pointer + src_member.offset_in_bytes };
        
        if type_is_union(dst_member.type) {
            if !remap_union(dst_member_any, src_member_any, src, src_member)  {
                log("Error: failed while remapping struct member (union) %!", dst_member.name);
                return false;
            }
        } else {
            // TODO: what if src is union, but dst is not?
            if !remap_data(dst_member_any, src_member_any)  {
                log("Error: failed while remapping struct member %!", dst_member.name);
                return false;
            }
        }
    }
    
    return true;
}

// union is just a struct where we want to only copy one member
// if we map one union to another, we actually want to map by the name of union member
// so we could just do a remap_struct, with an extra parameter for union_member, passing the 


/*
    Remapping Unions
    
    sometimes, the union itself contains all of the necessary information required to figure out the union should be treated as.
    (e.g.: a union of Entity types where all members of union contain the same base type as first member)
    
    But, many times we require more context, either in the form of an external type tag or enum value.
    If the parent_any is not provided, then 
    
    
    The parent Any may not be provided in the user callback, so the user needs to be aware of this and handle this case.
    src_member_ti will be provided if and only if src_parent is provided
    
    TODO: should we pass Data with context for src data here?
*/
remap_union :: (dst: Any, src: Any, src_parent: Any, src_member_info: *Type_Info_Struct_Member) -> bool {
    settings := context.data_packer.conversion_settings;
    
    assert(dst.type.type == .STRUCT);
    dst_ti := dst.type.(*Type_Info_Struct);
    assert(dst_ti.textual_flags & .UNION == .UNION);
    
    if !is_allowed(.REMAP_UNION) {
        log_unsupported_conversion(.REMAP_UNION, "remap_struct");
        return false;
    }
    
    // TODO: probably should support this, shouldn't be too hard
    if !type_is_union(src.type) {
        log("Error: Conversion from non-union type to union is not supported.");
        return false;
    }
    
    src_member: *Type_Info_Struct_Member;
    for settings.get_union_type_procs {
        src_member = it.proc(dst.type, .{ src, src_parent, src_member_info }, it.data);
        if src_member  break;
    }
    if !src_member  {
        // log("Warning: failed to resolve union member in remap_struct.");
        return true;
    }
    assert(src_member.flags & .CONSTANT == 0);
    
    // search for dst member matching src member
    last_dst_member_offset := -1;
    for dst_member: dst_ti.members {
        if dst_member.flags & .CONSTANT  continue;
        if dst_member.name == src_member.name {
            if !remap_data(
                Any.{ dst_member.type, dst.value_pointer + dst_member.offset_in_bytes }, 
                Any.{ src_member.type, src.value_pointer + src_member.offset_in_bytes }
            )  return false;
            
            return true;
        }
    }
    
    return true; // TODO?
}



type_is_union :: (ti: *Type_Info) -> bool {
    return ti.type == .STRUCT && (ti.(*Type_Info_Struct).textual_flags & .UNION);
}


/*
    What happens if we have some kind of change in type like
        [N] T to [M][N] T
    
    We would probably want the [N]u8 to map to the first row (M = 0) of the [M][N]u8
    But what we would actually get would be that the [N]u8's elements get spread across the M columns.
    So in order ot resolve this we would actually need to first calculate how much indirection there is in each case
        and then map the types so that the base type is what matches up.
    
    This is starting to get a bit complicated, and we also still can't really check ahead of time if the base types even *actually* match up or not
    All we have to go off of here is the number of levels of indirection, and the array types/counts
    We could implement some basic heuristics, but if we then want it to be configurable, it could be a bit much.
    
    But, we also don't want to just give up on arrays altogether...
    and going from a single value to an array of values is still very useful.
    
    current logic for single to array will actually probably work just fine
    but when it comes to nest arrays, things get tricky.
    pre-cheking level of indireciton is probably not a bad idea
    
    but then we have to think about array types as well, and that could get messy
    like for example
        [M][N] T -> [][N] T
        or 
        [M][N] T -> [M][..] T
    
*/

/*
    All array conversions are essentailly just view -> view, but each dst type has some distinct concerns
    
    if dst is 
        fixed
            we may be forced to lengthen or truncate src array
            and we don't currently have a means to store the actual length that was filled in here
        view
            need to consider whether we want a clone of the src, or just duplicate the view onto src's underlying data
            for now, we only do the copy, since this was created first to use with the data packer
        resizable
            need to consider setting the array's allocator
                we can't assume the allocator is already set, because the resizable array itself may have been dynamically created by the remapper
                should we do some lookup on array type that user specifies?
                should it be handled in a callback?
                we can't copy the allocator from src, because that's a pointer which will not be valid fi src was from a file
                
    

*/

// TODO: consider how allocators / allocations should work and what settings to implement
// Shallow copy vs deep copy options?
remap_array :: (dst: Any, src: Any) -> bool {
    /*
        remap_array is probably the most complex remapping case, since we need to handle not only the three array types, 
            but we also support remapping a single-element of a given type T to an array with element type T.
        
        Because of this, we need to pull out the type, value_pointer, and element_type from dst and src, 
            and then manually override those in certain cases. 
        So for the sake of keeping the code legible, dst and src should not be used directly at all beyond this header section.
    */
    
    // NOTE: src does not necessarily have to be an array here
    assert(dst.type.type == .ARRAY);
    
    src_type := src.type;
    dst_type := dst.type.(*Type_Info_Array);
    
    src_value_pointer := src.value_pointer;
    dst_value_pointer := dst.value_pointer;
    
    src_element_type: *Type_Info; // we figure this out later, once we can be sure src_type is an array
    dst_element_type := dst_type.element_type;
    
    conversion_type: Conversion_Types = .UNKNOWN_CONVERSION;
    
    // remap string to array of u8
    if src_type.type == .STRING {
        if dst_type.element_type == type_info(u8) {
            if dst_type.array_type == {
              case .FIXED;       conversion_type = .STRING_TO_FIXED_ARRAY;
              case .VIEW;        conversion_type = .STRING_TO_VIEW;
              case .RESIZABLE;   conversion_type = .STRING_TO_RESIZABLE;
            }
        }
        if !is_allowed(conversion_type) {
            if conversion_type 
                then log_disallowed_conversion (conversion_type, "remap_array");
                else log_unsupported_conversion(conversion_type, "remap_array");
            return false;
        }
        
        src_string_pointer := src_value_pointer.(*string);
        if dst_type.array_type == {
          case .FIXED;
            memcpy(dst_value_pointer, src_string_pointer.data, src_string_pointer.count);
          case .VIEW;
            // TODO: we would like to have an option as to whether this should copy
            dst_value_pointer.(*string).* = copy_string(src_string_pointer.*);
          case .RESIZABLE;
            array := dst_value_pointer.(*[..]u8);
            array_add(array, ..src_string_pointer.(*[]u8).*);
        }
        return true;
    }
    
    // TODO: I am unsure whether or not we should just do the conversion checks below separately from the switch to get src_data and src_elem_count...
    
    // now we determine src_element_type and conversion_type, as well as get src data and count
    src_count: int   = ---;
    src_data:  *void = ---;
    
    if src_type.type != .ARRAY {
        conversion_type  = .SINGLE_TO_ARRAY;
        src_element_type = src_type;
        src_count        = 1;
        src_data         = src_value_pointer;
    } else {
        src_element_type = src_type.(*Type_Info_Array).element_type;
        src_array_type  := src_type.(*Type_Info_Array).array_type;
        src_count, src_data = get_array_count_and_data(src_value_pointer, xx src_type);
        
        if dst_type.array_type == {
          case .FIXED;
            if src_array_type == {
              case .FIXED; 
                // TODO: we should probably notify the user if fixed array gets widened or truncated
                if src_count > dst_type.array_count {
                    conversion_type = .TRUNCATE_FIXED_ARRAY;
                } else if src_count < dst_type.array_count {
                    conversion_type = .WIDEN_FIXED_ARRAY;
                } else {
                    conversion_type = .NO_CONVERSION_REQUIRED;
                }
              case .VIEW;       conversion_type = .VIEW_TO_FIXED_ARRAY;
              case .RESIZABLE;  conversion_type = .VIEW_TO_FIXED_ARRAY;
            }
          case .VIEW;
            if dst_type.array_type == {
              case .FIXED;      conversion_type = .FIXED_ARRAY_TO_VIEW;
              case .VIEW;       conversion_type = .NO_CONVERSION_REQUIRED;
              case .RESIZABLE;  conversion_type = .RESIZABLE_ARRAY_TO_VIEW;
            }
          case .RESIZABLE;
            if dst_type.array_type == {
              case .FIXED;      conversion_type = .FIXED_ARRAY_OR_VIEW_TO_RESIZABLE; 
              case .VIEW;       conversion_type = .FIXED_ARRAY_OR_VIEW_TO_RESIZABLE;
              case .RESIZABLE;  conversion_type = .NO_CONVERSION_REQUIRED;
            }
        }
    }
    
    if !is_allowed(conversion_type) {
        if conversion_type 
            then log_disallowed_conversion (conversion_type, "remap_array");
            else log_unsupported_conversion(conversion_type, "remap_array");
        return false;
    }
    
    // if we have nothing to copy from src, then just return success
    if src_data == null || src_count == 0  return true;
    
    
    // we have to do a bit more work when getting dst data and count, 
    // since we actaully want to allocate for the view and resizable cases
    dst_count: int   = ---;
    dst_data:  *void = ---;
    
    if dst_type.array_type == {
      case .FIXED;
        dst_data  = dst_value_pointer;
        dst_count = dst_type.array_count;
        
      case .VIEW;
        raw_array := dst_value_pointer.(*Array_View_64);
        
        // NOTE: we only allocate new data for the array view if it is currently null, 
        //       otherwise, we assume that user pre-allocated a set amount of space.
        if raw_array.data == null {
            assert(raw_array.count == 0, "dst_count was %", raw_array.count);
            // TODO: give the user the ability to set allocators for array views' data
            raw_array.count = src_count;
            raw_array.data  = alloc(src_count * dst_type.element_type.runtime_size);
            memset(raw_array.data, 0, src_count * dst_type.element_type.runtime_size);
        } else {
            log("Warning: array view data was non-null in : data %, count %", raw_array.data, raw_array.count);
        }
        dst_count = raw_array.count;
        dst_data  = raw_array.data;
        
      case .RESIZABLE;
        raw_array := dst_value_pointer.(*Resizable_Array);
        
        // TODO: should we only reserve space when resizable array is empty, like in .VIEW case above?
        array_reserve_nonpoly(xx raw_array, src_count, dst_element_type.runtime_size);
        assert(raw_array.allocated == src_count);
        raw_array.count = src_count;
        
        dst_count = raw_array.count;
        dst_data  = raw_array.data;
    }
    
    if dst_data == null || dst_count == 0 {
        log("Error: dst array was null or empty in remap_array.");
        print_stack_trace(context.stack_trace, to_standard_error = false);
        return false;
    }
    
    
    // COPY ARRAY DATA
    
    // TODO: probably log some warning when array counts don't match?
    min_count    := min(src_count, dst_count);
    src_element_any := Any.{ src_element_type, src_data };
    dst_element_any := Any.{ dst_element_type, dst_data };
    
    for 0..min_count-1 {
        if !remap_data(dst_element_any, src_element_any) {
            log("Error: unable to remap data");
            return false;
        }
        src_element_any.value_pointer += src_element_type.runtime_size;
        dst_element_any.value_pointer += dst_element_type.runtime_size;
    }
    
    return true;
}

// check if we are allowed do it by name, else do it by value
remap_enum :: (dst: Any, src: Any) -> bool { 
    settings := *context.data_packer.conversion_settings;

    assert(src.type.type == .ENUM);
    assert(dst.type.type == .ENUM);
    
    src_ti := src.type.(*Type_Info_Enum);
    dst_ti := dst.type.(*Type_Info_Enum);
    
    // TODO: should we skip this if both src and dst are #specified?
    conversion := Conversion_Types.ENUM_BY_NAME;
    if is_allowed(conversion) {
        // TODO: This doesn't really handle enum_flags at all!
        // TODO: find out if int_to_int could cause issues with u64 -> s64 here
        
        // if we are mapping by name, then it really doesn't make sense to map an enum to enum_flags, does it?
        // for now, we will prohibit it
        if (dst_ti.enum_type_flags & .FLAGS) != (src_ti.enum_type_flags & .FLAGS) {
            log_disallowed_conversion(conversion, "remap_enum");
            return false;
        }
        
        if dst_ti.enum_type_flags & .FLAGS {
            src_s64, dst_s64: s64;
            enum_to_int(src_s64, src);
            
            for src_ti.values {
                if (it & src_s64) == it {
                    src_name := src_ti.names[it_index];
                    for dst_ti.names {
                        if it == src_name {
                            dst_s64 |= dst_ti.values[it_index];
                            break;
                        }
                    }
                }
            }
            
            int_to_enum(dst, dst_s64);
            return true;
        }
        else {
            src_s64: s64;
            enum_to_int(src_s64, src);
            
            src_value_name: string;
            for src_ti.values {
                if it == src_s64 {
                    src_value_name = src_ti.names[it_index];
                    break;
                }
            }
            
            if src_value_name {
                for dst_ti.names {
                    if it == src_value_name {
                        int_to_enum(dst, dst_ti.values[it_index]);
                        return true;
                    }
                }
            }
            
            // For now, if we are not able to match by name, we will still fallback to trying to match by value.
            // log("Error: unable to match enum value by name in %", conversion, proc_name);
            // return false;
        }
    }
    
    conversion = .ENUM_BY_VALUE;
    if is_narrowing_int(dst_ti.internal_type, src_ti.internal_type)  conversion |= .INT_NARROWING;
    if !is_allowed(conversion) {
        log_disallowed_conversion(conversion, "remap_enum");
        return false;
    }
    
    enum_to_enum(dst, src);
    return true;
}

remap_int :: inline (dst: Any, src: Any) -> bool {
    settings := *context.data_packer.conversion_settings;

    assert(dst.type.type == .INTEGER);
    
    if src.type.type == {
      case .ENUM; 
        conversion := Conversion_Types.ENUM_TO_INT;
        if is_narrowing_int(xx dst.type, src.type.(*Type_Info_Enum).internal_type)  conversion |= .INT_NARROWING;
        if !is_allowed(conversion) {
            log_disallowed_conversion(conversion, "remap_int");
            return false;
        }
        enum_to_int(dst, src);
        return true;
        
      case .INTEGER;
        conversion := Conversion_Types.INT_TO_INT;
        if is_narrowing_int(xx dst.type, xx src.type)  conversion |= .INT_NARROWING;
        if !is_allowed(conversion) {
            log_disallowed_conversion(conversion, "remap_int");
            return false;
        }
        int_to_int(dst, src);
        return true;
        
      case .FLOAT; 
        conversion := Conversion_Types.FLOAT_TO_INT;
        if !is_allowed(conversion) {
            log_disallowed_conversion(conversion, "remap_int");
            return false;
        }
        float_to_int(dst, src);
        return true;
        
      case .BOOL;
        return bool_to_any(dst, src);
    }
    
    return false;
}

remap_float :: inline (dst: Any, src: Any) -> bool {
    settings := *context.data_packer.conversion_settings;

    assert(dst.type.type == .FLOAT);
    
    if src.type.type == {
      case .ENUM; 
        conversion := Conversion_Types.ENUM_TO_FLOAT;
        if !is_allowed(conversion) {
            log_disallowed_conversion(conversion, "remap_float");
            return false;
        }
        enum_to_float(dst, src);
        return true;
        
      case .INTEGER;
        conversion := Conversion_Types.INT_TO_FLOAT;
        if !is_allowed(conversion) {
            log_disallowed_conversion(conversion, "remap_float");
            return false;
        }
        int_to_float(dst, src);
        return true;
        
      case .FLOAT; 
        conversion := Conversion_Types.FLOAT_TO_FLOAT;
        if is_narrowing_float(xx dst.type, xx src.type)  conversion |= .FLOAT_NARROWING;
        if !is_allowed(conversion) {
            log_disallowed_conversion(conversion, "remap_float");
            return false;
        }
        float_to_float(dst, src);
        return true;
        
      case .BOOL;
        return bool_to_any(dst, src);
    }
    
    return false;
}


/*
    In order to keep most of the basic casting / conversion functions useful as utilities, 
    they will take their relevant parameters explicitly rather than taking a Conversion_Settings.
    
    Need to do some actual testing with all the stuff I've written just now.
    With the basic types working, we need to implement the basic array cases
        first as simple utility functions
        then verify impl in remap_data
    Then probably integrate what we have and test with dyncall
    then make sure I didn't break the data packer
    then push changes
    
    then finally new stuff
        work on making the conversion settings meaningful
        work on the remapping pointers stuff
            table/callbacks for casting pointers up/down
    
    
    On function naming
    
    The simple "direct" converisons are just named like 'x_to_y'
        basically just switch cases to determine casts between primitve types
        may include some minimal checks or conversion rules
        both dst and src type are explicit, and we assert that the Any's are of the proper types
            (just as an indexing operation on an array view asserts that the index is in bounds, this will save the user trouble) 
    
    Any conversions which are doing some higher-level stuff are named like 'remap_x'
        Where x is the dst type.
        For these remap_x procs, the src type is not explicitly asserted, rather they should return an error for unspported or disallwed conversions
        remap_data is the most general proc, and here the dst type is not even asserted, so it can actually be anything
            this should be the only remap proc where we don't take the type as a given
        
    And by higher-level stuff I mean things like matching values by name, allocating data, or user callbacks
        remapping structs 
            based on names of members
        remapping pointers 
            recasting based on user callback
            deep copying may require allocation
        remapping enums 
            based on names of values
        remapping arrays
            copying may require allocation
            
    
    On strings
    
    For now, I plan not to directly include any functions for remapping strings into other types (like int, float, enum, array, struct, bool)
    That sort of extremely loose conversion sort of defeats the point of using a binary data format in the first place
    And all the conversions provided here are really meant to be in service of (primarily) the data packer, and (secondly) the dyncall module

    I kind of plan to have some basic conversions to other string types though, such as *u8 and []u8.
    And I will probably put in a simple way for the user to provide a 'any_to_string' proc
        so they can plug in their own thing if its relevant to their particular domain
        (I could see it maybe being useful for certain network applications?)
    
    
    
    
*/

// ========== Utility Conversions ==========

// TODO: probably should create versions of the x_to_bool and bool_to_x functions that match other interfaces and don't require return
// TODO: I think we should differentiate the any_to_x and remap_x procs

bool_to_any :: (dst: Any, src: Any) -> bool {
    assert(src.type.type == .BOOL);
    if dst.type.type == {
      case .BOOL;
        dst.value_pointer.(*bool).* = src.value_pointer.(*bool).*;
        return true;
        
      case .ENUM; #through;
      case .INTEGER;
        memset(src.value_pointer, 0, src.type.runtime_size);
        src.value_pointer.(*bool).* = dst.value_pointer.(*bool).*; // NOTE: little endian assumed?
        return true;
        
      case .FLOAT;
        f64_value: float64 = ifx src.value_pointer.(*bool).* then 1.0 else 0.0;
        if dst.type.runtime_size == {
          case 4; src.value_pointer.(*float32).* = f64_value.(float32);
          case 8; src.value_pointer.(*float64).* = f64_value;
        }
    }
    return false;
}

any_to_bool :: (dst: Any, src: Any) -> bool {
    assert(dst.type.type == .BOOL);
    if src.type.type == {
      case .BOOL; 
        dst.value_pointer.(*bool).* = src.value_pointer.(*bool).*;
        return true;
        
      case .ENUM; #through;
      case .INTEGER;
        ptr := (*src.value_pointer).(*u8);
        for 0..src.type.runtime_size-1 {
            if ptr.* != 0 {
                dst.value_pointer.(*bool).* = true;
                break;
            }
            ptr += 1;
        }
        return true;
        
      case .FLOAT;
        f64_value: float64;
        if src.type.runtime_size == {
          case 4; f64_value = src.value_pointer.(*float32).*.(float64);
          case 8; f64_value = src.value_pointer.(*float64).*;
        }
        if f64_value then dst.value_pointer.(*bool).* = true;
        return true;
    }
    return false;
}

is_narrowing_int :: (dst_ti: *Type_Info_Integer, src_ti: *Type_Info_Integer) -> bool {
    if src_ti.runtime_size > dst_ti.runtime_size  return true;
    if src_ti.signed {
        if !dst_ti.signed  return true;
    } else {
        if dst_ti.signed && src_ti.runtime_size == dst_ti.runtime_size  return true;
    }
    return false;
}

int_to_int :: (dst: Any, src: Any) {
    assert(src.type.type == .INTEGER);
    assert(dst.type.type == .INTEGER);
    
    src_ti := src.type.(*Type_Info_Integer);
    dst_ti := dst.type.(*Type_Info_Integer);
    
    // @IMPROVEMENT?: 
    // I had considered just doing a memcpy for either 64 bit type, 
    // but then we don't get range checking on u64 to s64.
    // But maybe I am overlooking some way we can make this neater?
    // Also, maybe we want to purposefully ignore the sign bit on u64 -> s64 because we use this proc for enums too?
    
    // if both are u64, then using s64 as an intermediate (as we do below) is problematic
    if src_ti == type_info(u64) && dst_ti == type_info(u64) {
        dst.value_pointer.(*u64).* = src.value_pointer.(*u64).*;
        return;
    }
    
    // all other cases we can use s64 as an intermediate and then we don't have to do the combinatorics
    // still have to switch on signedness though...
    s64_value: s64;
    if src_ti.signed {
        if src.type.runtime_size == {
          case 1; s64_value = src.value_pointer.(*s8 ).*.(s64);
          case 2; s64_value = src.value_pointer.(*s16).*.(s64);
          case 4; s64_value = src.value_pointer.(*s32).*.(s64);
          case 8; s64_value = src.value_pointer.(*s64).*.(s64);
        }
    } else {
        if src.type.runtime_size == {
          case 1; s64_value = src.value_pointer.(*u8 ).*.(s64);
          case 2; s64_value = src.value_pointer.(*u16).*.(s64);
          case 4; s64_value = src.value_pointer.(*u32).*.(s64);
          case 8; s64_value = src.value_pointer.(*u64).*.(s64);
        }
    }
    if dst_ti.signed {
        if dst.type.runtime_size == {
          case 1; dst.value_pointer.(*s8 ).* = s64_value.(s8 );
          case 2; dst.value_pointer.(*s16).* = s64_value.(s16);
          case 4; dst.value_pointer.(*s32).* = s64_value.(s32);
          case 8; dst.value_pointer.(*s64).* = s64_value.(s64);
        }
    } else {
        if dst.type.runtime_size == {
          case 1; dst.value_pointer.(*u8 ).* = s64_value.(u8 );
          case 2; dst.value_pointer.(*u16).* = s64_value.(u16);
          case 4; dst.value_pointer.(*u32).* = s64_value.(u32);
          case 8; dst.value_pointer.(*u64).* = s64_value.(u64);
        }
    }
}

float_to_int :: (dst: Any, src: Any) {
    assert(src.type.type == .FLOAT);
    assert(dst.type.type == .INTEGER);
    
    s64_value: s64;
    if src.type.runtime_size == {
        case 4; s64_value = src.value_pointer.(*float32).*.(s64);
        case 8; s64_value = src.value_pointer.(*float64).*.(s64);
    }
    if dst.type.(*Type_Info_Integer).signed {
        if dst.type.runtime_size == {
          case 1; dst.value_pointer.(*s8 ).* = s64_value.(s8 );
          case 2; dst.value_pointer.(*s16).* = s64_value.(s16);
          case 4; dst.value_pointer.(*s32).* = s64_value.(s32);
          case 8; dst.value_pointer.(*s64).* = s64_value.(s64);
        }
    } else {
        if dst.type.runtime_size == {
          case 1; dst.value_pointer.(*u8 ).* = s64_value.(u8 );
          case 2; dst.value_pointer.(*u16).* = s64_value.(u16);
          case 4; dst.value_pointer.(*u32).* = s64_value.(u32);
          case 8; dst.value_pointer.(*u64).* = s64_value.(u64);
        }
    }
}

enum_as_int :: inline (src: Any) -> Any {
    assert(src.type.type == .ENUM);
    return Any.{ src.type.(*Type_Info_Enum).internal_type, src.value_pointer };
}

// for convenience
int_to_enum   :: inline (dst: Any, src: Any) { int_to_int(enum_as_int(dst), src); }
enum_to_int   :: inline (dst: Any, src: Any) { int_to_int(dst, enum_as_int(src)); }
enum_to_enum  :: inline (dst: Any, src: Any) { int_to_int(enum_as_int(dst), enum_as_int(src)); }
float_to_enum :: inline (dst: Any, src: Any) { float_to_int(enum_as_int(dst), src); }
enum_to_float :: inline (dst: Any, src: Any) { int_to_float(dst, enum_as_int(src)); }



is_narrowing_float :: inline (dst_ti: *Type_Info_Float, src_ti: *Type_Info_Float) -> bool {
    return src_ti.runtime_size > dst_ti.runtime_size;
} 

float_to_float :: (dst: Any, src: Any) {
    assert(src.type.type == .FLOAT);
    assert(dst.type.type == .FLOAT);
    
    // nested switch here because there's only four cases; no point using an intermediate value
    if src.type.runtime_size == {
      case 4;
        if dst.type.runtime_size == {
          case 4; dst.value_pointer.(*float32).* = src.value_pointer.(*float32).*;
          case 8; dst.value_pointer.(*float64).* = src.value_pointer.(*float32).*.(float64);
        }
      case 8;
        if dst.type.runtime_size == {
          case 4; dst.value_pointer.(*float32).* = src.value_pointer.(*float64).*.(float32);
          case 8; dst.value_pointer.(*float64).* = src.value_pointer.(*float64).*;
        }
    }
}

int_to_float :: (dst: Any, src: Any) {
    assert(src.type.type == .INTEGER);
    assert(dst.type.type == .FLOAT);
    
    f64_value: float64;
    if src.type.runtime_size == {
        case 1; f64_value = src.value_pointer.(*s8 ).*.(float64);
        case 2; f64_value = src.value_pointer.(*s16).*.(float64);
        case 4; f64_value = src.value_pointer.(*s32).*.(float64);
        case 8; f64_value = src.value_pointer.(*s64).*.(float64);
    }
    
    if dst.type.runtime_size == {
        case 4; dst.value_pointer.(*float32).* = f64_value.(float32);
        case 8; dst.value_pointer.(*float64).* = f64_value.(float64);
    }
}


/*
    For use in cases where a union's type is determined by some tag in the parent struct.
    
    Some_Struct :: struct {
        union_type: enum  { ... };
        some_union: union { ... };
    }
    
    TODO: write a proc to generate the lookup Resolve_Union_By_Tag_Data for Tagged_Union
    
    I should document this because I forgot it and then had to figure out why I did it this way again...
    So the reason there's a union_ti passed in here is because we can't actually match on src type, since it may be some dynamically loaded type info
    So we want to match the dst union type to what is in the user data and then just verify that the src type is also a union
    In cases where we know we can use src type, we will just have to pass it as union_ti as well
*/
resolve_union_by_external_tag : Resolve_Union_Proc : (union_ti: *Type_Info, src: Data_With_Context, data: *void) -> *Type_Info_Struct_Member {
    user_data := data.(*Resolve_Union_By_Tag_Data);
    
    if union_ti != user_data.union_type  return null;
    if src.parent.value_pointer == null  return null;
    if data                     == null  return null;
    
    src_ti := src.data.type.(*Type_Info_Struct);
    assert(src_ti.type == .STRUCT);
    assert(src_ti.textual_flags & .UNION == .UNION);
    
    dst_tag_any := Small_Any.{ user_data.tag_type };
    
    src_tag_field := get_field(xx src.parent.type, user_data.tag_member_name);
    src_tag_any   := get_member_any(src.parent.value_pointer, src_tag_field);
    if !remap_data(dst_tag_any, src_tag_any)  return null;
    
    src_member_name: string;
    for user_data.lookup {
        if it.tag_value == dst_tag_s64.value_number {
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

/*
    For when all union members share some common base type, and that base type contains the type tag for the union.
    
    Entity_Type :: enum { .KNIGHT; .GOBLIN; ... };
    Entity_Base :: struct {
        entity_type:    Entity_Type;
        health:         int;
        ...
    }
    Knight :: struct { 
        using #as base: Entity_Base;
        ...
    }
    Goblin :: struct { 
        using #as base: Goblin;
        ...
    }
    Entity_Union :: union {
        using #as base: Entity_Base;
        knight:         Knight;
        goblin:         Goblin;
        ...
    }
    
    resolve_entity_union_data := Resolve_Union_By_Tag_Data.{ "type", type_info(Entity_Union), type_info(Entity_Type), .[
        .{ #run Number_Union.from(Entity_Type.KNIGHT),  "knight" },
        .{ #run Number_Union.from(Entity_Type.GOBLIN),  "goblin" },
    ]};
    array_add(*context.data_packer.conversion_settings.get_union_type_procs, .{ resolve_union_by_tag, resolve_entity_union_data });
    
    
    The need to use a #run on Number_Union.from() is less than ideal, but I have more confidence after switching 
        to using the Number_Union that the code is correct and won't fail for enums with smaller backing integer sizes.
    And the rest of this is also not really ideal anyhow, so I'm not gonna worry about making it 2% nicer 
        until I figure out a way to make the 98% of union remapping less clunky and horrible.
*/
resolve_union_by_internal_tag : Resolve_Union_Proc : (union_ti: *Type_Info, src: Data_With_Context, data: *void) -> *Type_Info_Struct_Member {
    user_data := data.(*Resolve_Union_By_Tag_Data);
    
    if union_ti != user_data.union_type  return null;
    if data == null  return null;
    
    src_ti := src.data.type.(*Type_Info_Struct);
    assert(src_ti.type == .STRUCT);
    assert(src_ti.textual_flags & .UNION == .UNION);
    
    dst_tag_any := Small_Any.{ user_data.tag_type };
    
    src_tag_field := get_field(xx src.data.type, user_data.tag_member_name);
    src_tag_any   := get_member_any(src.data.value_pointer, src_tag_field);
    if !remap_data(dst_tag_any, src_tag_any)  return null;
    
    src_member_name: string;
    for user_data.lookup {
        if it.tag_value == dst_tag_any.value_number {
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
    tag_member_name:    string;
    tag_type:           *Type_Info_Enum;
    union_type:         *Type_Info;
    lookup:             [] struct { tag_value: Number_Union; member_name: string; };
}
