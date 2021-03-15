/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.exception;

import dyaml : Mark, Node;

@safe:

///
T loadEnforce(T)(T value, lazy string msg, lazy Node node) pure
{
    import std.exception : enforce;
    return enforce(value, new LoadError(msg, node));
}

///
class LoadError : Exception
{
    ///
    this(string msg, Node node) nothrow pure
    {
        auto mark = node.startMark;
        super(msg, mark.name, mark.line+1);
        this.column = mark.column+1;
    }

    ulong column;
}

///
class SignalException : Exception
{
    import std.exception : basicExceptionCtors;
    mixin basicExceptionCtors;
}
