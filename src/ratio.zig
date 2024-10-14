/// returns a Ratio struct with field `top: IntType` and `bottom: UnsignedIntType`,
/// where IntType is the parameter type, and UnsignedIntType is a unsigned int with the
/// same bit size as IntType.
/// This struct is twice the size of the given int type, ignoring padding.
pub fn Ratio(IntType: type) type {
    const int_type_info = @typeInfo(IntType);
    const UnsignedIntType = std.meta.Int(false, int_type_info.Int.bits);
    return struct {
        top: IntType,
        bottom: UnsignedIntType,
    };
}

const std = @import("std");
const meta = std.meta;
