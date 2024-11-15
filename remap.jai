
Conversion_Types :: enum_flags u64 {
    UNKNOWN_CONVERSION     :: 0;
    NO_CONVERSION_REQUIRED :: 1;
    
    INT_TO_INT;
    INT_NARROWING;
    FLOAT_TO_FLOAT;
    FLOAT_NARROWING;
    
    INT_TO_FLOAT;
    FLOAT_TO_INT;
    
    // Maybe we just have a flag for enum_as_int? As this is really the only important cast that occurs
    // I doubt that anyone would need to allow enum to int but not int to enum or vice versa
    // ENUM_AS_INT;            // if allowed, we then follow the integer rules for the underlying type
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
    
    COPY_VIEW; // copy the actual underlying data pointed to by array views, so that dst view owns the underlying data.
    
    
    REMAP_STRUCT;
    REMAP_UNION;    // currently hardcoded as unsupported
    REMAP_THROUGH_POINTER;
    RECAST_POINTER;
    
    // composite values
    // we can't differentiate these two...
    // ENUM_TO_INT   :: INT_TO_INT   | ENUM_AS_INT;
    // INT_TO_ENUM   :: INT_TO_INT   | ENUM_AS_INT;
    // ENUM_TO_FLOAT :: INT_TO_FLOAT | ENUM_AS_INT;
    // FLOAT_TO_ENUM :: FLOAT_TO_INT | ENUM_AS_INT;
    
    ALL :: 0xFFFF_FFFF_FFFF_FFFF;
}

Conversion_Settings :: struct {
    allowed_conversions   : Conversion_Types;
    float_to_int_rounding : enum { TRUNCATE; FLOOR; CEIL; NEAREST; };
    pointer_recast_procs  : [..] struct { proc: Pointer_Recast_Proc; data: *void; };
    get_union_type_procs  : [..] struct { proc: Get_Union_Type_Proc; data: *void; };
    
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
// returns true if the Any has been recast, false if not
// this is only for casting down to a more specific type (e.g.: casting a *Type_Info down to a *Type_Info_Enum)
Pointer_Recast_Proc :: #type (any: Any, data: *void) -> (Any, bool);
Get_Union_Type_Proc :: #type (dst_ti: *Type_Info, src: Any, src_parent: Any, src_member_ti: *Type_Info_Struct_Member, data: *void) -> *Type_Info_Struct_Member;
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

log_disallowed_conversion :: inline (conversion: Conversion_Types, proc_name: string) {
    log("Error: disallowed conversion % in %", conversion, proc_name);
}

log_unsupported_conversion :: inline (conversion: Conversion_Types, proc_name: string) {
    log("Error: unsupported conversion % in %", conversion, proc_name);
}

default_conversion_settings := DEFAULT_CONVERSION_SETTINGS;
DEFAULT_CONVERSION_SETTINGS :: Conversion_Settings.{
    allowed_conversions   = .ALL,
    float_to_int_rounding = .TRUNCATE,
};





// The most general remapping procedure. 
// Handles any dst and src types.
remap_data :: (dst: Any, src: Any) -> bool {
    settings := *context.data_packer.conversion_settings;
    
    // for now we are not requiring that src subtype and dst subtype match up top
    // for the cases where this matters, we check those individually
    
    // print("remapping % -> %\n", src.type.type, dst.type.type);
    
    // TODO: handling for type info variant 
    // TODO: maybe move handling for pointers up top 
    
    if dst.type.type == {
      case .STRING;
        if src.type.type != dst.type.type  return false; 
        // TODO: we would like to have an option as to whether this should copy
        (cast(*string) dst.value_pointer).* = copy_string((cast(*string) src.value_pointer).*);
        return true;
        
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
            (cast(**void)dst.value_pointer).* = dst_derefed.value_pointer;
        }
        
        // if this fails, we should deallocate the dynamic_new'd item
        return remap_data(dst_derefed, src_derefed);
        
      // case .VARIANT;
    }
    
    return true;
}

remap_struct :: (dst: Any, src: Any) -> bool {
    settings := *context.data_packer.conversion_settings;

    assert(src.type.type == .STRUCT);
    assert(dst.type.type == .STRUCT);
    
    if !is_allowed(.REMAP_STRUCT) {
        log_unsupported_conversion(.REMAP_STRUCT, "remap_struct");
        return false;
    }
    
    dst_ti := cast(*Type_Info_Struct) dst.type;
    src_ti := cast(*Type_Info_Struct) src.type;
    
    
    // we can provide some instances of this proc type for common methods of disambiguationg union type
    // e.g. one for Tagged_Union (polymorphic, or as Any), one for separate type tag, one for enum -> Type mapping table
    // maybe even one using struct member note to determine tag for union
    
    
    // if dst is a union, then we need to know which member ot use
    // but the problem is we can only determine which member is set in src
    // we also want to be able to go from any type to union if union contains compatible member?
    //      but we also need some means to set dst tag from src?
    // 
    
    /*
        NOTE: ignoring #place struct members
        
        If we do not ignore #place members, we will end up doing a lot of duplicate work.
        
        I am not sure if we will ever have very nice handling for #place struct members, since they are highly problematic to remapping.
        Generally, most #place members are used to provide an alternative way of accessing the data held in a struct, for example:
            'xy' and 'yz' members in a Vector3
            'floats' and 'coefs' members in a mat4
        These are essentially 0-cost getters, or an alternativ einterface to the same underlying data.
        
        This is unlike a union, because a union is typically storing two different pieces of data in the same memory space.
        I am sure there is probably some niche use case for #place where the members actually serve to encode unique data, but since it is uncommon, I have not really considered how to make affordances for that use case.
    */
    
    
    
    // TODO: once we have union working, we can go back to using <= in the below #place checks
    
    // TODO: if src_union_member, then only match this one member to dst
    
    // remap elements by name
    last_dst_member_offset := -1;
    for dst_member: dst_ti.members {
        if dst_member.flags & .CONSTANT  continue;
        if dst_member.offset_in_bytes < last_dst_member_offset  {
            break; // ignoring #place members. Wish there were a better way to do this.
        }
        last_dst_member_offset = dst_member.offset_in_bytes;
        
        
        last_src_member_offset := -1;
        for src_member: src_ti.members {
            if src_member.flags & .CONSTANT  continue;
            if src_member.offset_in_bytes < last_src_member_offset  {
                break; // ignoring #place members. Wish there were a better way to do this.
            }
            last_src_member_offset = src_member.offset_in_bytes;
            
            if dst_member.name == src_member.name {
                // print("remapping member % to % (%)\n", src_member.name, dst_member.name, type_info_to_type(dst_member.type));
                
                /*
                    We have to handle unions here, since we have the context of them as struct members
                    (unfortunately, because now we have a fat ass loop here)
                
                    if dst_member is union
                        if src_member is union
                            determine src type
                            match member from src -> dst
                        else
                            if dst contains member of src type
                            (in this case, we can't set any tag for dst (unless we wanted to have a callback for that, but that sounds horrible tbh))
                    
                    
                    new problem
                    
                    we can't do a switch on type inside a user callback to determine parent struct type
                    because this may be a dynamically loaded type info
                    so then the only option is to do a compare on the struct name
                        maybe that's just what we have to deal with, OR...
                        (name compare is problematic especially for parameterized structs, but also just for name changes)
                    
                    maybe we should pass the dst type info as well, so the user can check that to figure what rule to apply
                        then attempt to apply that rule to src data
                        
                    
                    do we actually care to pass the src Type info struct member?
                        does not seem to provide any useful additional data...
                    
                */
                
                dst_member_any := Any.{ dst_member.type, dst.value_pointer + dst_member.offset_in_bytes };
                src_member_any := Any.{ src_member.type, src.value_pointer + src_member.offset_in_bytes };
                
                if type_is_union(dst_member.type) {
                    if !remap_union(dst_member_any, src_member_any, src, *src_member)  {
                        log("failed while remapping struct member (union) %!", dst_member.name);
                        return false;
                    }
                } else {
                    // TODO: what if src is union, but dst is not?
                    if !remap_data(dst_member_any, src_member_any)  {
                        log("failed while remapping struct member %!", dst_member.name);
                        return false;
                    }
                }
                
                break src_member;
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
*/
remap_union :: (dst: Any, src: Any, src_parent: Any, src_tism: *Type_Info_Struct_Member) -> bool {
    settings := context.data_packer.conversion_settings;
    
    assert(dst.type.type == .STRUCT);
    dst_ti := cast(*Type_Info_Struct) dst.type;
    assert(dst_ti.textual_flags & .UNION == .UNION);
    
    if !is_allowed(.REMAP_UNION) {
        log_unsupported_conversion(.REMAP_UNION, "remap_struct");
        return false;
    }
    
    // Maybe TODO
    if !type_is_union(src.type) {
        log("Error: Conversion from non-union type to union is not supported.");
        return false;
    }
    
    src_member: *Type_Info_Struct_Member;
    for settings.get_union_type_procs {
        src_member = it.proc(dst.type, src, src_parent, src_tism, it.data);
        if src_member  break;
    }
    if !src_member  {
        log("Warning: failed to resolve union member in remap_struct.");
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
    return ti.type == .STRUCT && ((cast(*Type_Info_Struct)ti).textual_flags & .UNION);
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
    settings := *context.data_packer.conversion_settings;

    assert(dst.type.type == .ARRAY);
    // assert(src.type.type == .ARRAY); // src can sometimes be dst.element_type
    
    _src := src; // so we can override in single to array case
    
    dst_ti := cast(*Type_Info_Array) dst.type;
    src_ti := cast(*Type_Info_Array) _src.type;
    
    // so we an override for 'array-of-one' case
    // NOTE: it is important that we don't access the type info of the element type through _src or src_ti directly now, as this will be invalid in the 'single to array' case
    src_elem_type  := src_ti.element_type; 
    
    conversion_type: Conversion_Types = .UNKNOWN_CONVERSION;
    
    
    // TODO: I am unsure whether or not we should just do the conversion checks below separately from the switch to get src_data and src_elem_count...
    
    // We use this as stack storage for backing array view in the case we have a SINGLE_TO_ARRAY conversion.
    // In theory, it would be better to have an any with type info for a [1] T, but we can't really do that. We also now cannot rely on src_ti.element_type to be accurate
    array_of_one: Array_View_64;
    if _src.type.type != .ARRAY {
        conversion_type = .SINGLE_TO_ARRAY;
        array_of_one = .{ 1, _src.value_pointer };
        src_elem_type = _src.type;
        _src = array_of_one;
        src_ti := type_info([] u8);
    }
    else { // array to array
        if dst_ti.array_type == {
          case .FIXED;
            if src_ti.array_type == {
              case .FIXED     ; 
                  // TODO: we should probably notify the user if array gets widened or truncated
                if src_ti.array_count > dst_ti.array_count {
                    conversion_type = .TRUNCATE_FIXED_ARRAY;
                } else if src_ti.array_count < dst_ti.array_count {
                    conversion_type = .WIDEN_FIXED_ARRAY;
                } else {
                    conversion_type = .NO_CONVERSION_REQUIRED;
                }
              case .VIEW      ; conversion_type = .VIEW_TO_FIXED_ARRAY;
              case .RESIZABLE ; conversion_type = .VIEW_TO_FIXED_ARRAY;
            }
          case .VIEW;
            if dst_ti.array_type == {
              case .FIXED     ; conversion_type = .FIXED_ARRAY_TO_VIEW;
              case .VIEW      ; conversion_type = .NO_CONVERSION_REQUIRED;
              case .RESIZABLE ; conversion_type = .RESIZABLE_ARRAY_TO_VIEW;
            }
          case .RESIZABLE;
            if dst_ti.array_type == {
              case .FIXED     ; conversion_type = .FIXED_ARRAY_OR_VIEW_TO_RESIZABLE; 
              case .VIEW      ; conversion_type = .FIXED_ARRAY_OR_VIEW_TO_RESIZABLE;
              case .RESIZABLE ; conversion_type = .NO_CONVERSION_REQUIRED;
            }
        }
    }
    
    if !is_allowed(conversion_type) {
        if conversion_type 
            then log_disallowed_conversion(conversion_type, "remap_array");
            else log_unsupported_conversion(conversion_type, "remap_array");
        return false;
    }
    
    
    src_data       : *void = ---;
    src_elem_count : int   = ---;
    
    if src_ti.array_type == .FIXED {
        src_data       = _src.value_pointer;
        src_elem_count = src_ti.array_count;
    } else {
        raw_array := cast(*Resizable_Array) _src.value_pointer;
        src_data       = raw_array.data;
        src_elem_count = raw_array.count;
    }             
    
    if src_data == null || src_elem_count == 0  return true;
    
    
    dst_data       : *void = ---;
    dst_elem_count : int   = ---;
    
    if dst_ti.array_type == {
      case .FIXED;
        dst_data       = dst.value_pointer;
        dst_elem_count = dst_ti.array_count;
        
      case .VIEW;
        raw_array := cast(*Resizable_Array) dst.value_pointer;
        dst_data       = raw_array.data;
        dst_elem_count = raw_array.count;
        if dst_data == null || dst_elem_count < 0 {
            // TODO: set allocators for array views' data
            raw_array.data  = alloc(src_elem_count * dst_ti.element_type.runtime_size);
            raw_array.count = src_elem_count;
            
            dst_data       = raw_array.data;
            dst_elem_count = raw_array.count;
        }
        
      case .RESIZABLE;
        // TODO: verify that cap is set properly ?
        raw_array := cast(*Resizable_Array) dst.value_pointer;
        array_reserve_nonpoly(xx raw_array, src_elem_count, dst_ti.element_type.runtime_size);
        raw_array.count = src_elem_count;
        dst_data        = raw_array.data;
        dst_elem_count  = raw_array.count;
    }
    
    if dst_data == null || dst_elem_count == 0 {
        log("Error: array was null or empty");
        return false;
    }
    
    
    min_count := min(dst_elem_count, src_elem_count);
    
    src_elem_any := Any.{ src_elem_type, src_data };
    dst_elem_any := Any.{ dst_ti.element_type, dst_data };
    
    // TOOD: don't remap elements if they are of the same type! Just memcopy!
    // problem: we can't ever just memcopy a struct or array since we are basically doing a deep copy, and also may remap thorugh pointers
    // if are_types_equivalent(dst_ti.element_type, src_elem_type) {
    //     memcpy(dst_data, src_data, src_elem_type.runtime_size * min_count);
    // }
    
    for 0..min_count-1 {
        if !remap_data(dst_elem_any, src_elem_any) {
            log("Error: unable to remap data");
            return false;
        }
        src_elem_any.value_pointer += src_elem_type.runtime_size;
        dst_elem_any.value_pointer += dst_ti.element_type.runtime_size;
    }
    
    return true;
}

// check if we are allowed do it by name, else do it by value
remap_enum :: (dst: Any, src: Any) -> bool { 
    settings := *context.data_packer.conversion_settings;

    assert(src.type.type == .ENUM);
    assert(dst.type.type == .ENUM);
    
    src_ti := cast(*Type_Info_Enum) src.type;
    dst_ti := cast(*Type_Info_Enum) dst.type;
    
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
        if is_narrowing_int(xx dst.type, (cast(*Type_Info_Enum)src.type).internal_type)  conversion |= .INT_NARROWING;
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
        (cast(*bool)dst.value_pointer).* = (cast(*bool)src.value_pointer).*;
        return true;
        
      case .ENUM; #through;
      case .INTEGER;
        memset(src.value_pointer, 0, src.type.runtime_size);
        (cast(*bool)src.value_pointer).* = (cast(*bool)dst.value_pointer).*; // NOTE: little endian assumed?
        return true;
        
      case .FLOAT;
        f64_value: float64 = ifx (cast(*bool)src.value_pointer).* then 1.0 else 0.0;
        if dst.type.runtime_size == {
          case 4; (cast(*float32)src.value_pointer).* = cast(float32) f64_value;
          case 8; (cast(*float64)src.value_pointer).* = cast(float64) f64_value;
        }
    }
    return false;
}

any_to_bool :: (dst: Any, src: Any) -> bool {
    assert(dst.type.type == .BOOL);
    if src.type.type == {
      case .BOOL; 
        (cast(*bool)dst.value_pointer).* = (cast(*bool)src.value_pointer).*;
        return true;
        
      case .ENUM; #through;
      case .INTEGER;
        ptr := cast(*u8) *src.value_pointer;
        for 0..src.type.runtime_size-1 {
            if ptr.* != 0 {
                (cast(*bool)dst.value_pointer).* = true;
                break;
            }
            ptr += 1;
        }
        return true;
        
      case .FLOAT;
        f64_value: float64;
        if src.type.runtime_size == {
          case 4; f64_value = cast(float64) (cast(*float32)src.value_pointer).*;
          case 8; f64_value = cast(float64) (cast(*float64)src.value_pointer).*;
        }
        if f64_value then (cast(*bool)dst.value_pointer).* = true;
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
    
    src_ti := cast(*Type_Info_Integer) src.type;
    dst_ti := cast(*Type_Info_Integer) dst.type;
    
    // @IMPROVEMENT?: 
    // I had considered just doing a memcpy for either 64 bit type, 
    // but then we don't get range checking on u64 to s64.
    // But maybe I am overlooking some way we can make this neater?
    // Also, maybe we want to purposefully ignore the sign bit on u64 -> s64 because we use this proc for enums too?
    
    // if both are u64, then using s64 as an intermediate (as we do below) is problematic
    if src_ti == type_info(u64) && dst_ti == type_info(u64) {
        (cast(*u64)dst.value_pointer).* = (cast(*u64)src.value_pointer).*;
        return;
    }
    
    // all other cases we can use s64 as an intermediate and then we don't have to do the combinatorics
    // still have to switch on signedness though...
    s64_value: s64;
    if src.type.runtime_size == {
      case 1;
        if src_ti.signed then s64_value = cast(s64) (cast(*s8 )src.value_pointer).*;
                         else s64_value = cast(s64) (cast(*u8 )src.value_pointer).*;
      case 2;
        if src_ti.signed then s64_value = cast(s64) (cast(*s16)src.value_pointer).*;
                         else s64_value = cast(s64) (cast(*u16)src.value_pointer).*;
      case 4;
        if src_ti.signed then s64_value = cast(s64) (cast(*s32)src.value_pointer).*;
                         else s64_value = cast(s64) (cast(*u32)src.value_pointer).*;
      case 8;
        if src_ti.signed then s64_value = cast(s64) (cast(*s64)src.value_pointer).*;
                         else s64_value = cast(s64) (cast(*u64)src.value_pointer).*;
    }
    if dst.type.runtime_size == {
      case 1; 
        if dst_ti.signed then (cast(*s8 )dst.value_pointer).* = cast(s8 ) s64_value;
                         else (cast(*u8 )dst.value_pointer).* = cast(u8 ) s64_value;
      case 2; 
        if dst_ti.signed then (cast(*s16)dst.value_pointer).* = cast(s16) s64_value;
                         else (cast(*u16)dst.value_pointer).* = cast(u16) s64_value;
      case 4; 
        if dst_ti.signed then (cast(*s32)dst.value_pointer).* = cast(s32) s64_value;
                         else (cast(*u32)dst.value_pointer).* = cast(u32) s64_value;
      case 8; 
        if dst_ti.signed then (cast(*s64)dst.value_pointer).* = cast(s64) s64_value;
                         else (cast(*u64)dst.value_pointer).* = cast(u64) s64_value;
    }
}

float_to_int :: (dst: Any, src: Any) {
    assert(src.type.type == .FLOAT);
    assert(dst.type.type == .INTEGER);
    
    s64_value: s64;
    if src.type.runtime_size == {
        case 4; s64_value = cast(s64) (cast(*float32)src.value_pointer).*;
        case 8; s64_value = cast(s64) (cast(*float64)src.value_pointer).*;
    }
    if dst.type.runtime_size == {
        case 1; (cast(*s8 )dst.value_pointer).* = cast(s8 ) s64_value;
        case 2; (cast(*s16)dst.value_pointer).* = cast(s16) s64_value;
        case 4; (cast(*s32)dst.value_pointer).* = cast(s32) s64_value;
        case 8; (cast(*s64)dst.value_pointer).* = cast(s64) s64_value;
    }
}

enum_as_int :: inline (src: Any) -> Any {
    assert(src.type.type == .ENUM);
    return Any.{ (cast(*Type_Info_Enum)src.type).internal_type, src.value_pointer };
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
          case 4; (cast(*float32)dst.value_pointer).* =               (cast(*float32)src.value_pointer).*;
          case 8; (cast(*float64)dst.value_pointer).* = cast(float64) (cast(*float32)src.value_pointer).*;
        }
      case 8;
        if dst.type.runtime_size == {
          case 4; (cast(*float32)dst.value_pointer).* = cast(float32) (cast(*float64)src.value_pointer).*;
          case 8; (cast(*float64)dst.value_pointer).* =               (cast(*float64)src.value_pointer).*;
        }
    }
}

int_to_float :: (dst: Any, src: Any) {
    assert(src.type.type == .INTEGER);
    assert(dst.type.type == .FLOAT);
    
    f64_value: float64;
    if src.type.runtime_size == {
        case 1; f64_value = cast(float64) (cast(*s8  )src.value_pointer).*;
        case 2; f64_value = cast(float64) (cast(*s16 )src.value_pointer).*;
        case 4; f64_value = cast(float64) (cast(*s32 )src.value_pointer).*;
        case 8; f64_value = cast(float64) (cast(*s64 )src.value_pointer).*;
    }
    
    if dst.type.runtime_size == {
        case 4; (cast(*float32)dst.value_pointer).* = cast(float32) f64_value;
        case 8; (cast(*float64)dst.value_pointer).* = cast(float64) f64_value;
    }
}



// ========== Helper Procs ==========

// would it be good to cache the results of these type equivalence comparisons in the context of something like remap_data?
// seems like it could actually end up taking us quite a lot of time to run the comparison that, perhaps we would just be faster just to do the normal remapping
// this seems like the kind of thing where we would actually want to run some benchmarks, but that's not in scope for me right now...
// it could be that right now we don't actually want to do this comparison, especially if all our trivial types like int and and float don't get stored by data packer and instead get specially encoded
// LATER: the struct case may actually be much better to precheck if we have an array of structs, since we only have to do the type checking once and skip remapping each individual instance

// two types are considered equivalent if we can memcpy between the two types validly.
are_types_equivalent :: (ti1: *Type_Info, ti2: *Type_Info) -> bool {
    if ti1.type != ti2.type  return false;
    if ti1.runtime_size != ti2.runtime_size  return false;
    if ti1.type == {
      case .STRUCT;
        return are_structs_equivalent(xx ti1, xx ti2);
        
      case .ARRAY;
        ti1_array := cast(*Type_Info_Array) ti1;
        ti2_array := cast(*Type_Info_Array) ti2;
        return ti1_array.array_type == ti2_array.array_type && are_types_equivalent(ti1_array.element_type, ti2_array.element_type);
        
      case .ENUM;
        // on what criteria are two enums equivalent?
        // based only on internal type?
        // would we want to do a more structural check here?
        ti1_enum := cast(*Type_Info_Enum) ti1;
        ti2_enum := cast(*Type_Info_Enum) ti2;
        return  ti1_enum.internal_type.signed == ti2_enum.internal_type.signed; 
        
      case .INTEGER;
        ti1_integer := cast(*Type_Info_Integer) ti1;
        ti2_integer := cast(*Type_Info_Integer) ti2;
        return ti1_integer.signed == ti2_integer.signed; 
        
      case .FLOAT;
        // we already checked that runtime size matches
        return true; 
    }
}

are_structs_equivalent :: (ti1: *Type_Info_Struct, ti2: *Type_Info_Struct) -> bool {
    assert(ti1.type == .STRUCT);
    assert(ti2.type == .STRUCT);
    
    if ti1.runtime_size  != ti2.runtime_size   return false;
    if ti1.members.count != ti2.members.count  return false;
    
    // TODO: validate that all members have the exact same names and types
    // TODO: ignore constant members and #place members
    for ti1_member: ti1.members {
        ti2_member := ti2.members[it_index];
        if (ti1_member.flags & .CONSTANT) != (ti2_member.flags & .CONSTANT)  return false;
        if !are_types_equivalent(ti1_member.type, ti2_member.type)  return false;
    }
    
    return true;
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
    user_data := cast(*Resolve_Union_By_Tag_Data) data;
    
    log("dst_type: %", type_info_to_type(user_data.dst_type));
    
    if dst_ti != user_data.dst_type  return null;
    if !src_parent.value_pointer  return null;
    if !data  return null;
    
    src_ti := cast(*Type_Info_Struct) src.type;
    assert(src_ti.type == .STRUCT);
    assert(src_ti.textual_flags & .UNION == .UNION);
    
    dst_tag: s64;
    src_tag := get_member_any(src_parent.value_pointer, get_field(xx src_parent.type, user_data.tag_member_name));
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
    tag_member_name : string;
    tag_type        : *Type_Info_Enum;
    dst_type        : *Type_Info;
    lookup          : [] struct { tag_value: s64; member_name: string; };
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
    if !member  return Any.{};
    
    return get_member_any(parent.value_pointer, member);
}

get_member_any :: (parent_ptr: *void, member_ti: *Type_Info_Struct_Member) -> Any {
    if !member_ti  return Any.{};
    value_pointer := parent_ptr + member_ti.offset_in_bytes;
    return Any.{ member_ti.type, value_pointer };
}





#scope_module

recast_type_info :: (any: Any) -> Any {
    if any.type == type_info(*Type_Info) {
        ti := (cast(**Type_Info) any.value_pointer).*;
        if ti.type == {
            case .INTEGER              ; return Any.{ type_info(*Type_Info_Integer),   any.value_pointer };
            case .FLOAT                ; return Any.{ type_info(*Type_Info_Float),     any.value_pointer };
            case .STRING               ; return Any.{ type_info(*Type_Info_String),    any.value_pointer };
            case .POINTER              ; return Any.{ type_info(*Type_Info_Pointer),   any.value_pointer };
            case .PROCEDURE            ; return Any.{ type_info(*Type_Info_Procedure), any.value_pointer };
            case .STRUCT               ; return Any.{ type_info(*Type_Info_Struct),    any.value_pointer };
            case .ARRAY                ; return Any.{ type_info(*Type_Info_Array),     any.value_pointer };
            case .ENUM                 ; return Any.{ type_info(*Type_Info_Enum),      any.value_pointer };
            case .VARIANT              ; return Any.{ type_info(*Type_Info_Variant),   any.value_pointer };
            // case .BOOL                 ; return Any.{ type_info(*Type_Info_Bool), any.value_pointer };
            // case .VOID                 ; return Any.{ type_info(*Type_Info_Void), any.value_pointer };
            // case .OVERLOAD_SET         ; return Any.{ type_info(*Type_Info_Overlaod_Set), any.value_pointer };
            // case .ANY                  ; return Any.{ type_info(*Type_Info_Any), any.value_pointer };
            // case .POLYMORPHIC_VARIABLE ; return Any.{ type_info(*Type_Info_Polymorphic_Variable), any.value_pointer };
            // case .TYPE                 ; return Any.{ type_info(*Type_Info_Type), any.value_pointer };
            // case .CODE                 ; return Any.{ type_info(*Type_Info_Code), any.value_pointer };
        }
    }
    return any;
}

deref_any_pointer :: (any: Any) -> Any, bool {
    if any.type.type == .POINTER {
        return Any.{
            (cast(*Type_Info_Pointer)any.type).pointer_to,
            (cast(**void)any.value_pointer).*
        }, true;
    }
    return any, false;
}

// restores the value of a variable at this time upon scope exit
defer_restore :: (value: $T) #expand {
    value_before := value;
    `defer value = value_before;
}

unwrap_variant_type :: (any: Any) -> Any {
    if any.type.type == .VARIANT {
        return Any.{
            (cast(*Type_Info_Variant)any.type).variant_of,
            any.value_pointer
        }, true;
    }
    return any, false;
}

// TODO: maybe move this to some utils file if we do keep it around
type_info_to_type :: inline (ti: *Type_Info) -> Type {
    return (cast(*Type)*ti).*;
}