module medal.types;

import std.typecons;
import sumtype;

@safe:

alias ValueType = SumType!(Int);

///
enum SpecialPatterns
{
    Any = "_",
    Stdout = "STDOUT",
    Stderr = "STDERR",
    Return = "RETURN",
}

///
struct CommandResult
{
    import std.stdio: File;
    ///
    Nullable!string stdout;
    ///
    Nullable!string stderr;
    ///
    Nullable!int code;
}

///
struct Int
{
    ///
    int i;

    string toString() const
    {
        import std.conv: to;
        return i.to!string;
    }
    ///
    static Nullable!ValueType fromString(string s) @safe pure nothrow
    {
        import std.conv: to, ConvException;
        try
        {
            return ValueType(Int(s.to!int)).nullable;
        }
        catch(ConvException)
        {
            import std.experimental.logger: errorf;
            import std.exception: assumeWontThrow;
            debug errorf("Unknown value for int: `%s`", s).assumeWontThrow;
            return typeof(return).init;
        }
        catch(Exception) 
        {
            import std.experimental.logger: errorf;
            import std.exception: assumeWontThrow;
            debug errorf("Unexpected exception when converting `%s` to int", s).assumeWontThrow;
            return typeof(return).init;
        }
    }

    ///
    static Nullable!ValueType fromEventPattern(string pat, ValueType val) @safe pure nothrow
    in(isValidInputPattern(pat))
    {
        switch(pat)
        {
        case SpecialPatterns.Any: return val.nullable;
        default: return fromString(pat).get == val ? val.nullable : typeof(return).init;
        }
    }

    ///
    static bool isValidInputPattern(string pat) @safe pure nothrow
    {
        return pat == SpecialPatterns.Any || !fromString(pat).isNull;
    }
}

alias VariableType = SumType!(MedalType!Int);

///
struct MedalType(T)
{
    ///
    Nullable!ValueType fromString(string s) const @safe pure nothrow
    {
        return T.fromString(s);
    }

    ///
    Nullable!ValueType fromEventPattern(string pat, ValueType val) const @safe pure nothrow
    {
        return T.fromEventPattern(pat, val);
    }

    ///
    Nullable!ValueType fromOutputPattern(string pat, CommandResult result) const @trusted
    {
        import std.conv: to;
        import std.stdio: File;
        import std.string: chomp;
        switch(pat)
        {
        case SpecialPatterns.Stdout: return T.fromString(File(result.stdout.get).readln.chomp);
        case SpecialPatterns.Stderr: return T.fromString(File(result.stderr.get).readln.chomp);
        case SpecialPatterns.Return: return T.fromString(result.code.get.to!string);
        default:                     return T.fromString(pat);
        }
    }

    ///
    bool isValidInputPattern(string pat) @safe pure nothrow
    {
        return T.isValidInputPattern(pat);
    }
}
