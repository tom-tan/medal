/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.message;

import medal.transition.core : BindingElement;

import std.concurrency : thisTid, Tid;

@safe:

///
struct SignalSent
{
    ///
    this(int no) @nogc nothrow pure
    {
        no_ = no;
    }

    ///
    int no() const @nogc nothrow pure
    {
        return no_;
    }
private:
    int no_;
}


///
struct TransitionSucceeded
{
    ///
    this(in BindingElement tokenElems)
    {
        tokenElements = tokenElems;
        tid = thisTid;
    }

    BindingElement tokenElements;
    Tid tid;
}

///
struct TransitionFailed
{
    ///
    this(in BindingElement tokenElems, in string c = "")
    {
        tokenElements = tokenElems;
        tid = thisTid;
        cause = c;
    }
    BindingElement tokenElements;
    Tid tid;
    string cause;
}

///
struct TransitionInterrupted
{
    ///
    this(in BindingElement tokenElems)
    {
        tokenElements = tokenElems;
        tid = thisTid;
    }
    BindingElement tokenElements;
    Tid tid;
}