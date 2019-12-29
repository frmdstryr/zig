const std = @import("std");
const expect = std.testing.expect;

pub const TokenList = std.SegmentedList(CToken, 32);

pub const CToken = struct {
    id: Id,
    bytes: []const u8,
    num_lit_suffix: NumLitSuffix = .None,

    pub const Id = enum {
        CharLit,
        StrLit,
        NumLitInt,
        NumLitFloat,
        Identifier,
        Plus,
        Minus,
        Slash,
        LParen,
        RParen,
        Eof,
        Dot,
        Asterisk, // *
        Ampersand, // &
        And, // &&
        Assign, // =
        Or, // ||
        Bang, // !
        Tilde, // ~
        Shl, // <<
        Shr, // >>
        Lt, // <
        Lte, // <=
        Gt, // >
        Gte, // >=
        Eq, // ==
        Ne, // !=
        Increment, // ++
        Decrement, // --
        Comma,
        Fn,
        Arrow, // ->
        LBrace,
        RBrace,
        Pipe,
    };

    pub const NumLitSuffix = enum {
        None,
        F,
        L,
        U,
        LU,
        LL,
        LLU,
    };
};


pub fn ctoken(id: CToken.Id, bytes: []const u8) CToken {
    return CToken{.id = id, .bytes = bytes};
}

pub fn cnumtoken(suffix: CToken.NumLitSuffix, bytes: []const u8,) CToken {
    return CToken{
        .id = if (suffix == .F) .NumLitFloat else .NumLitInt,
        .bytes = bytes,
        .num_lit_suffix = suffix
    };
}


pub fn tokenizeCMacro(tl: *TokenList, chars: [*:0]const u8) !void {
    var index: usize = 0;
    var first = true;
    while (true) {
        const tok = try next(chars, &index);
        if (tok.id == .StrLit or tok.id == .CharLit)
            try tl.push(try zigifyEscapeSequences(tl.allocator, tok))
        else
            try tl.push(tok);
        if (tok.id == .Eof)
            return;
        if (first) {
            // distinguish NAME (EXPR) from NAME(ARGS)
            first = false;
            if (chars[index] == '(') {
                try tl.push(.{
                    .id = .Fn,
                    .bytes = "",
                });
            }
        }
    }
}

fn zigifyEscapeSequences(allocator: *std.mem.Allocator, tok: CToken) !CToken {
    for (tok.bytes) |c| {
        if (c == '\\') {
            break;
        }
    } else return tok;
    var bytes = try allocator.alloc(u8, tok.bytes.len * 2);
    var state: enum {
        Start,
        Escape,
        Hex,
        Octal,
    } = .Start;
    var i: usize = 0;
    var count: u8 = 0;
    var num: u8 = 0;
    for (tok.bytes) |c| {
        switch (state) {
            .Escape => {
                switch (c) {
                    'n', 'r', 't', '\\', '\'', '\"' => {
                        bytes[i] = c;
                    },
                    '0'...'7' => {
                        count += 1;
                        num += c - '0';
                        state = .Octal;
                        bytes[i] = 'x';
                    },
                    'x' => {
                        state = .Hex;
                        bytes[i] = 'x';
                    },
                    'a' => {
                        bytes[i] = 'x';
                        i += 1;
                        bytes[i] = '0';
                        i += 1;
                        bytes[i] = '7';
                    },
                    'b' => {
                        bytes[i] = 'x';
                        i += 1;
                        bytes[i] = '0';
                        i += 1;
                        bytes[i] = '8';
                    },
                    'f' => {
                        bytes[i] = 'x';
                        i += 1;
                        bytes[i] = '0';
                        i += 1;
                        bytes[i] = 'C';
                    },
                    'v' => {
                        bytes[i] = 'x';
                        i += 1;
                        bytes[i] = '0';
                        i += 1;
                        bytes[i] = 'B';
                    },
                    '?' => {
                        i -= 1;
                        bytes[i] = '?';
                    },
                    'u', 'U' => {
                        // TODO unicode escape sequences
                        return error.TokenizingFailed;
                    },
                    else => {
                        // unknown escape sequence
                        return error.TokenizingFailed;
                    },
                }
                i += 1;
                if (state == .Escape)
                    state = .Start;
            },
            .Start => {
                if (c == '\\') {
                    state = .Escape;
                }
                bytes[i] = c;
                i += 1;
            },
            .Hex => {
                switch (c) {
                    '0'...'9' => {
                        num = std.math.mul(u8, num, 16) catch return error.TokenizingFailed;
                        num += c - '0';
                    },
                    'a'...'f' => {
                        num = std.math.mul(u8, num, 16) catch return error.TokenizingFailed;
                        num += c - 'a' + 10;
                    },
                    'A'...'F' => {
                        num = std.math.mul(u8, num, 16) catch return error.TokenizingFailed;
                        num += c - 'A' + 10;
                    },
                    else => {
                        i += std.fmt.formatIntBuf(bytes[i..], num, 16, false, std.fmt.FormatOptions{ .fill = '0', .width = 2 });
                        num = 0;
                        if (c == '\\')
                            state = .Escape
                        else
                            state = .Start;
                        bytes[i] = c;
                        i += 1;
                    },
                }
            },
            .Octal => {
                switch (c) {
                    '0'...'7' => {
                        count += 1;
                        num = std.math.mul(u8, num, 8) catch return error.TokenizingFailed;
                        num += c - '0';
                        if (count < 3)
                            continue;
                    },
                    else => {},
                }
                i += std.fmt.formatIntBuf(bytes[i..], num, 16, false, std.fmt.FormatOptions{ .fill = '0', .width = 2 });
                state = .Start;
                count = 0;
                num = 0;
            },
        }
    }
    if (state == .Hex or state == .Octal)
        i += std.fmt.formatIntBuf(bytes[i..], num, 16, false, std.fmt.FormatOptions{ .fill = '0', .width = 2 });
    return CToken{
        .id = tok.id,
        .bytes = bytes[0..i],
    };
}

fn next(chars: [*:0]const u8, i: *usize) !CToken {
    var state: enum {
        Start,
        GotLt,
        GotGt,
        GotPlus,
        GotMinus,
        GotAmpersand,
        GotPipe,
        GotBang,
        GotEq,
        CharLit,
        OpenComment,
        Comment,
        CommentStar,
        Backslash,
        String,
        Identifier,
        Decimal,
        Octal,
        GotZero,
        Hex,
        Bin,
        Float,
        ExpSign,
        FloatExp,
        FloatExpFirst,
        NumLitIntSuffixU,
        NumLitIntSuffixL,
        NumLitIntSuffixLL,
        NumLitIntSuffixUL,
        Done,
    } = .Start;

    var result = CToken{
        .bytes = "",
        .id = .Eof,
    };
    var begin_index: usize = 0;
    var digits: u8 = 0;
    var pre_escape = state;

    while (true) {
        const c = chars[i.*];
        if (c == 0) {
            switch (state) {
                .Identifier,
                .Decimal,
                .Hex,
                .Bin,
                .Octal,
                .GotZero,
                .Float,
                .FloatExp,
                => {
                    result.bytes = chars[begin_index..i.*];
                    return result;
                },
                .Start,
                .GotMinus,
                .Done,
                .NumLitIntSuffixU,
                .NumLitIntSuffixL,
                .NumLitIntSuffixUL,
                .NumLitIntSuffixLL,
                .GotLt,
                .GotGt,
                .GotPlus,
                .GotAmpersand,
                .GotPipe,
                .GotBang,
                .GotEq,
                => {
                    return result;
                },
                .CharLit,
                .OpenComment,
                .Comment,
                .CommentStar,
                .Backslash,
                .String,
                .ExpSign,
                .FloatExpFirst,
                => return error.TokenizingFailed,
            }
        }
        switch (state) {
            .Start => {
                switch (c) {
                    ' ', '\t', '\x0B', '\x0C' => {},
                    '\'' => {
                        state = .CharLit;
                        result.id = .CharLit;
                        begin_index = i.*;
                    },
                    '\"' => {
                        state = .String;
                        result.id = .StrLit;
                        begin_index = i.*;
                    },
                    '/' => {
                        state = .OpenComment;
                    },
                    '\\' => {
                        state = .Backslash;
                    },
                    '\n', '\r' => {
                        return result;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .Identifier;
                        result.id = .Identifier;
                        begin_index = i.*;
                    },
                    '1'...'9' => {
                        state = .Decimal;
                        result.id = .NumLitInt;
                        begin_index = i.*;
                    },
                    '0' => {
                        state = .GotZero;
                        result.id = .NumLitInt;
                        begin_index = i.*;
                    },
                    '.' => {
                        result.id = .Dot;
                        state = .Done;
                    },
                    '<' => {
                        result.id = .Lt;
                        state = .GotLt;
                    },
                    '>' => {
                        result.id = .Gt;
                        state = .GotGt;
                    },
                    '(' => {
                        result.id = .LParen;
                        state = .Done;
                    },
                    ')' => {
                        result.id = .RParen;
                        state = .Done;
                    },
                    '*' => {
                        result.id = .Asterisk;
                        state = .Done;
                    },
                    '+' => {
                        result.id = .Plus;
                        state = .GotPlus;
                    },
                    '-' => {
                        result.id = .Minus;
                        state = .GotMinus;
                    },
                    '!' => {
                        result.id = .Bang;
                        state = .GotBang;
                    },
                    '~' => {
                        result.id = .Tilde;
                        state = .Done;
                    },
                    '=' => {
                        result.id = .Assign;
                        state = .GotEq;
                    },
                    ',' => {
                        result.id = .Comma;
                        state = .Done;
                    },
                    '[' => {
                        result.id = .LBrace;
                        state = .Done;
                    },
                    ']' => {
                        result.id = .RBrace;
                        state = .Done;
                    },
                    '|' => {
                        result.id = .Pipe;
                        state = .GotPipe;
                    },
                    '&' => {
                        result.id = .Ampersand;
                        state = .GotAmpersand;
                    },
                    else => return error.TokenizingFailed,
                }
            },
            .Done => return result,
            .GotMinus => {
                switch (c) {
                    '>' => {
                        result.id = .Arrow;
                        state = .Done;
                    },
                    '-' => {
                        result.id = .Decrement;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .GotPlus => {
                switch (c) {
                    '+' => {
                        result.id = .Increment;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .GotLt => {
                switch (c) {
                    '<' => {
                        result.id = .Shl;
                        state = .Done;
                    },
                    '=' => {
                        result.id = .Lte;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .GotGt => {
                switch (c) {
                    '>' => {
                        result.id = .Shr;
                        state = .Done;
                    },
                    '=' => {
                        result.id = .Gte;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .GotPipe => {
                switch (c) {
                    '|' => {
                        result.id = .Or;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .GotAmpersand => {
                switch (c) {
                    '&' => {
                        result.id = .And;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .GotBang => {
                switch (c) {
                    '=' => {
                        result.id = .Ne;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .GotEq => {
                switch (c) {
                    '=' => {
                        result.id = .Eq;
                        state = .Done;
                    },
                    else => return result,
                }
            },
            .Float => {
                switch (c) {
                    '.', '0'...'9' => {},
                    'e', 'E' => {
                        state = .ExpSign;
                    },
                    'f',
                    'F',
                    => {
                        result.num_lit_suffix = .F;
                        result.bytes = chars[begin_index..i.*];
                        state = .Done;
                    },
                    'l', 'L' => {
                        result.num_lit_suffix = .L;
                        result.bytes = chars[begin_index..i.*];
                        state = .Done;
                    },
                    else => {
                        result.bytes = chars[begin_index..i.*];
                        return result;
                    },
                }
            },
            .ExpSign => {
                switch (c) {
                    '+', '-' => {
                        state = .FloatExpFirst;
                    },
                    '0'...'9' => {
                        state = .FloatExp;
                    },
                    else => return error.TokenizingFailed,
                }
            },
            .FloatExpFirst => {
                switch (c) {
                    '0'...'9' => {
                        state = .FloatExp;
                    },
                    else => return error.TokenizingFailed,
                }
            },
            .FloatExp => {
                switch (c) {
                    '0'...'9' => {},
                    'f', 'F' => {
                        result.num_lit_suffix = .F;
                        result.bytes = chars[begin_index..i.*];
                        state = .Done;
                    },
                    'l', 'L' => {
                        result.num_lit_suffix = .L;
                        result.bytes = chars[begin_index..i.*];
                        state = .Done;
                    },
                    else => {
                        result.bytes = chars[begin_index..i.*];
                        return result;
                    },
                }
            },
            .Decimal => {
                switch (c) {
                    '0'...'9' => {},
                    '\'' => {},
                    'u', 'U' => {
                        state = .NumLitIntSuffixU;
                        result.num_lit_suffix = .U;
                        result.bytes = chars[begin_index..i.*];
                    },
                    'l', 'L' => {
                        state = .NumLitIntSuffixL;
                        result.num_lit_suffix = .L;
                        result.bytes = chars[begin_index..i.*];
                    },
                    '.' => {
                        result.id = .NumLitFloat;
                        state = .Float;
                    },
                    else => {
                        result.bytes = chars[begin_index..i.*];
                        return result;
                    },
                }
            },
            .GotZero => {
                switch (c) {
                    'x', 'X' => {
                        state = .Hex;
                    },
                    'b', 'B' => {
                        state = .Bin;
                    },
                    '.' => {
                        state = .Float;
                        result.id = .NumLitFloat;
                    },
                    'u', 'U' => {
                        state = .NumLitIntSuffixU;
                        result.num_lit_suffix = .U;
                        result.bytes = chars[begin_index..i.*];
                    },
                    'l', 'L' => {
                        state = .NumLitIntSuffixL;
                        result.num_lit_suffix = .L;
                        result.bytes = chars[begin_index..i.*];
                    },
                    else => {
                        i.* -= 1;
                        state = .Octal;
                    },
                }
            },
            .Octal => {
                switch (c) {
                    '0'...'7' => {},
                    '8', '9' => return error.TokenizingFailed,
                    else => {
                        result.bytes = chars[begin_index..i.*];
                        return result;
                    },
                }
            },
            .Hex => {
                switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {},
                    'u', 'U' => {
                        // marks the number literal as unsigned
                        state = .NumLitIntSuffixU;
                        result.num_lit_suffix = .U;
                        result.bytes = chars[begin_index..i.*];
                    },
                    'l', 'L' => {
                        // marks the number literal as long
                        state = .NumLitIntSuffixL;
                        result.num_lit_suffix = .L;
                        result.bytes = chars[begin_index..i.*];
                    },
                    else => {
                        result.bytes = chars[begin_index..i.*];
                        return result;
                    },
                }
            },
            .Bin => {
                switch (c) {
                    '0'...'1' => {},
                    '2'...'9' => return error.TokenizingFailed,
                    'u', 'U' => {
                        // marks the number literal as unsigned
                        state = .NumLitIntSuffixU;
                        result.num_lit_suffix = .U;
                        result.bytes = chars[begin_index..i.*];
                    },
                    'l', 'L' => {
                        // marks the number literal as long
                        state = .NumLitIntSuffixL;
                        result.num_lit_suffix = .L;
                        result.bytes = chars[begin_index..i.*];
                    },
                    else => {
                        result.bytes = chars[begin_index..i.*];
                        return result;
                    },
                }
            },
            .NumLitIntSuffixU => {
                switch (c) {
                    'l', 'L' => {
                        result.num_lit_suffix = .LU;
                        state = .NumLitIntSuffixUL;
                    },
                    else => {
                        return result;
                    },
                }
            },
            .NumLitIntSuffixL => {
                switch (c) {
                    'l', 'L' => {
                        result.num_lit_suffix = .LL;
                        state = .NumLitIntSuffixLL;
                    },
                    'u', 'U' => {
                        result.num_lit_suffix = .LU;
                        state = .Done;
                    },
                    else => {
                        return result;
                    },
                }
            },
            .NumLitIntSuffixLL => {
                switch (c) {
                    'u', 'U' => {
                        result.num_lit_suffix = .LLU;
                        state = .Done;
                    },
                    else => {
                        return result;
                    },
                }
            },
            .NumLitIntSuffixUL => {
                switch (c) {
                    'l', 'L' => {
                        result.num_lit_suffix = .LLU;
                        state = .Done;
                    },
                    else => {
                        return result;
                    },
                }
            },
            .Identifier => {
                switch (c) {
                    '_', 'a'...'z', 'A'...'Z', '0'...'9' => {},
                    else => {
                        result.bytes = chars[begin_index..i.*];
                        return result;
                    },
                }
            },
            .String => {
                switch (c) {
                    '\"' => {
                        result.bytes = chars[begin_index .. i.* + 1];
                        state = .Done;
                    },
                    else => {},
                }
            },
            .CharLit => {
                switch (c) {
                    '\'' => {
                        result.bytes = chars[begin_index .. i.* + 1];
                        state = .Done;
                    },
                    else => {},
                }
            },
            .OpenComment => {
                switch (c) {
                    '/' => {
                        return result;
                    },
                    '*' => {
                        state = .Comment;
                    },
                    else => {
                        result.id = .Slash;
                        state = .Done;
                    },
                }
            },
            .Comment => {
                switch (c) {
                    '*' => {
                        state = .CommentStar;
                    },
                    else => {},
                }
            },
            .CommentStar => {
                switch (c) {
                    '/' => {
                        state = .Start;
                    },
                    else => {
                        state = .Comment;
                    },
                }
            },
            .Backslash => {
                switch (c) {
                    ' ', '\t', '\x0B', '\x0C' => {},
                    '\n', '\r' => {
                        state = .Start;
                    },
                    else => return error.TokenizingFailed,
                }
            },
        }
        i.* += 1;
    }
    unreachable;
}


fn expectTokens(tl: *TokenList, src: [*:0]const u8, expected: []CToken) void {
    tokenizeCMacro(tl, src) catch unreachable;
    var it = tl.iterator(0);
    for (expected) |t| {
        var tok = it.next().?;
        std.testing.expectEqual(t.id, tok.id);
        if (t.bytes.len > 0) {
            //std.debug.warn("  {} = {}\n", .{tok.bytes, t.bytes});
            std.testing.expectEqualSlices(u8, tok.bytes, t.bytes);
        }
        if (t.num_lit_suffix != .None) {
            std.testing.expectEqual(t.num_lit_suffix, tok.num_lit_suffix);
        }
    }
    std.testing.expect(it.next() == null);
    tl.shrink(0);
}


test "tokenize macro" {
    var tl = TokenList.init(std.heap.page_allocator);
    defer tl.deinit();

    expectTokens(&tl, "TEST(0\n", &[_]CToken{
        ctoken(.Identifier, "TEST"),
        ctoken(.Fn, ""),
        ctoken(.LParen, ""),
        ctoken(.NumLitInt, "0"),
        ctoken(.Eof, ""),
    });

    expectTokens(&tl, "__FLT_MIN_10_EXP__ -37\n", &[_]CToken{
        ctoken(.Identifier, "__FLT_MIN_10_EXP__"),
        ctoken(.Minus, ""),
        ctoken(.NumLitInt, "37"),
        ctoken(.Eof, ""),
    });

    expectTokens(&tl, "__llvm__ 1\n#define", &[_]CToken{
        ctoken(.Identifier, "__llvm__"),
        ctoken(.NumLitInt, "1"),
        ctoken(.Eof, ""),

    });

    expectTokens(&tl, "TEST 2", &[_]CToken{
        ctoken(.Identifier, "TEST"),
        ctoken(.NumLitInt, "2"),
        ctoken(.Eof, ""),

    });

    expectTokens(&tl, "FOO 0ull", &[_]CToken{
        ctoken(.Identifier, "FOO"),
        cnumtoken(.LLU, "0"),
        ctoken(.Eof, ""),

    });

}



test "tokenize macro ops" {
    var tl = TokenList.init(std.heap.page_allocator);
    defer tl.deinit();

    expectTokens(&tl, "ADD A + B", &[_]CToken{
        ctoken(.Identifier, "ADD"),
        ctoken(.Identifier, "A"),
        ctoken(.Plus, ""),
        ctoken(.Identifier, "B"),
        ctoken(.Eof, ""),
    });

     expectTokens(&tl, "ADD (A) + B", &[_]CToken{
        ctoken(.Identifier, "ADD"),
        ctoken(.LParen, ""),
        ctoken(.Identifier, "A"),
        ctoken(.RParen, ""),
        ctoken(.Plus, ""),
        ctoken(.Identifier, "B"),
        ctoken(.Eof, ""),
    });

    expectTokens(&tl, "ADD (A) + B", &[_]CToken{
        ctoken(.Identifier, "ADD"),
        ctoken(.LParen, ""),
        ctoken(.Identifier, "A"),
        ctoken(.RParen, ""),
        ctoken(.Plus, ""),
        ctoken(.Identifier, "B"),
        ctoken(.Eof, ""),
    });
}

test "escape sequences" {
    var buf: [1024]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(buf[0..]);
    const a = &alloc.allocator;
    expect(std.mem.eql(u8, (try zigifyEscapeSequences(a, .{
        .id = .StrLit,
        .bytes = "\\x0077",
    })).bytes, "\\x77"));
    expect(std.mem.eql(u8, (try zigifyEscapeSequences(a, .{
        .id = .StrLit,
        .bytes = "\\24500",
    })).bytes, "\\xa500"));
    expect(std.mem.eql(u8, (try zigifyEscapeSequences(a, .{
        .id = .StrLit,
        .bytes = "\\x0077 abc",
    })).bytes, "\\x77 abc"));
    expect(std.mem.eql(u8, (try zigifyEscapeSequences(a, .{
        .id = .StrLit,
        .bytes = "\\045abc",
    })).bytes, "\\x25abc"));
}
