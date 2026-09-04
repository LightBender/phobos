/**
Default compilation driver for `tools/measure_templates.d` when measuring
`std.utf` string-overload collapsing.

Instantiates the public string APIs across char/wchar/dchar and the usual
qualifier set (`mutable` / `const` / `immutable`). Range overloads are included
so trampolines are not the only instantiations in the object file.
*/
module measure_utf_driver;

import std.meta : AliasSeq;
import std.utf;

private void consumeString(S)(S s)
{
    if (!s.length)
        return;

    auto n = stride(s, 0);
    n += stride(s);
    n += strideBack(s);
    n += strideBack(s, s.length);
    n += codeLength!(typeof(cast() s[0]))(s);
    n += codeLength!char(s);
    n += codeLength!wchar(s);
    n += codeLength!dchar(s);
    cast(void) isValidUTF(s);
    if (false)
        validate(s);
    foreach (c; s.byUTF!char)
        n += c != 0;
    foreach (c; s.byUTF!wchar)
        n += c != 0;
    foreach (c; s.byUTF!dchar)
        n += c != 0;
    cast(void) n;
}

private struct FrontPop(C)
{
    const(C)[] s;
    @property bool empty() const { return s.length == 0; }
    @property C front() const { return s[0]; }
    void popFront() { s = s[1 .. $]; }
}

private struct BidirCU(C)
{
    const(C)[] s;
    @property bool empty() const { return s.length == 0; }
    @property C front() const { return s[0]; }
    @property C back() const { return s[$ - 1]; }
    void popFront() { s = s[1 .. $]; }
    void popBack() { s = s[0 .. $ - 1]; }
    @property auto save() { return this; }
}

void useAutodecodableStrings()
{
    consumeString("hello " ~ "\u00E9" ~ " " ~ "\U00010437");
    consumeString("hello "w ~ "\u00E9"w ~ " "w ~ "\U00010437"w);
    consumeString("hello "d ~ "\u00E9"d ~ " "d ~ "\U00010437"d);

    consumeString(("hello " ~ "\u00E9").dup);
    consumeString(("hello "w ~ "\u00E9"w).dup);
    consumeString(("hello "d ~ "\u00E9"d).dup);

    const(char)[] c8 = "hello";
    const(wchar)[] c16 = "hello"w;
    const(dchar)[] c32 = "hello"d;
    consumeString(c8);
    consumeString(c16);
    consumeString(c32);

    immutable(char)[] i8 = "hello";
    immutable(wchar)[] i16 = "hello"w;
    immutable(dchar)[] i32 = "hello"d;
    consumeString(i8);
    consumeString(i16);
    consumeString(i32);
}

void useGenericRanges()
{
    auto r8 = FrontPop!char("hello");
    auto r16 = FrontPop!wchar("hello"w);
    auto r32 = FrontPop!dchar("hello"d);
    cast(void) stride(r8);
    cast(void) stride(r16);
    cast(void) stride(r32);
    cast(void) codeLength!char(r8);
    cast(void) codeLength!wchar(r16);
    cast(void) codeLength!dchar(r32);

    auto b8 = BidirCU!char("hello");
    auto b16 = BidirCU!wchar("hello"w);
    auto b32 = BidirCU!dchar("hello"d);
    cast(void) strideBack(b8);
    cast(void) strideBack(b16);
    cast(void) strideBack(b32);
}

void main()
{
    useAutodecodableStrings();
    useGenericRanges();
}
