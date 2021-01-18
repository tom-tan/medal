/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.exception;

import dyaml : Node;

@safe:

///
T loadEnforce(T)(T value, lazy string msg, lazy Node node, string file) pure
{
    import std.exception : enforce;
    return enforce(value, new LoadError(msg, node, file));
}

///
class LoadError : Exception
{
    ///
    this(string msg, Node node, string file) @nogc nothrow pure
    {
        super(msg, file);
    }
}

///
class SignalException : Exception
{
    import std.exception : basicExceptionCtors;
    mixin basicExceptionCtors;
}