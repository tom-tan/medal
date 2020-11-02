/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition;

import std;
import std.experimental.logger;

version(unittest)
shared static this()
{
    sharedLog.logLevel = LogLevel.off;
}

///
enum SpecialPattern
{
    Any = "_", ///
    Stdout = "STDOUT", ///
    Stderr = "STDERR", ///
    Return = "RETURN", ///
}

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
struct CommandResult
{
    ///
    string stdout;
    ///
    string stderr;
    ///
    int code;
}

///
struct Place
{
    ///
    this(string n, string ns = "") inout pure
    {
        namespace = ns;
        name = n;
    }

    size_t toHash() const nothrow pure @safe
    {
        return name.hashOf(namespace.hashOf);
    }

    bool opEquals(ref const Place other) const pure
    {
        return namespace == other.namespace && name == other.name;
    }

    ///
    string toString() const pure
    {
        return namespace.empty ? name : namespace~"::"~name;
    }

    string namespace;
    string name;
    // Type type
}

///
class Token
{
    ///
    this(string val) pure
    {
        value = val;
    }

    override bool opEquals(in Object other) const pure
    {
        if (auto t = cast(const Token)other)
        {
            return value == t.value;
        }
        else
        {
            return false;
        }
    }

    ///
    override string toString() const pure
    {
        return value;
    }

    // Type type
    string value;
}

///
struct InputPattern
{
    ///
    const(Token) match(in Token token) const pure
    {
        switch(pattern) with(SpecialPattern)
        {
        case Any:
            return token;
        default:
            return pattern == token.value ? token : null;
        }
    }
    string pattern;
    // Type type
}

///
struct OutputPattern
{
    ///
    Token match(in CommandResult result) const pure
    {
        switch(pattern) with(SpecialPattern)
        {
        case Stdout:
            return new Token(result.stdout);
        case Stderr:
            return new Token(result.stderr);
        case Return:
            return new Token(result.code.to!string);
        default:
            return new Token(pattern);
        }
    }
    string pattern;
    // Type type
}

///
struct TransitionSucceeded
{
    BindingElement tokenElements;
}

///
struct TransitionFailed
{
    BindingElement tokenElements;
}

// std.concurrency cannot send/receive immutable AA
// https://issues.dlang.org/show_bug.cgi?id=13930 (solved by Issue 21296)
//alias BindingElement = immutable Token[Place];
alias BindingElement = immutable BindingElement_;
///
immutable class BindingElement_
{
    ///
    this() pure { tokenElements = (Token[Place]).init; }

    ///
    this(immutable Token[Place] tokenElems) pure
    {
        tokenElements = tokenElems;
    }

    ///
    bool opEquals(in Token[Place] otherTokenElements) const
    {
        return cast(const(Token[Place]))tokenElements == otherTokenElements;
    }

    bool empty() pure
    {
        return tokenElements.empty;
    }

    ///
    string toString() pure
    {
        return tokenElements.to!string;
    }

    Token[Place] tokenElements;
}

///
alias ArcExpressionFunction = immutable OutputPattern[Place];

///
BindingElement apply(ArcExpressionFunction aef, CommandResult result) pure
{
    auto tokenElems = aef.byPair.map!((kv) {
        auto place = kv.key;
        auto pat = kv.value;
        return tuple(place, pat.match(result));
    }).assocArray;
    return new BindingElement(tokenElems.assumeUnique);
}

///
unittest
{
    ArcExpressionFunction aef;
    auto be = aef.apply(CommandResult.init);
    assert(be.tokenElements.empty);
}

///
unittest
{
    immutable aef = [
        Place("foo"): OutputPattern("constant-value"),
    ];
    auto be = aef.apply(CommandResult.init);
    assert(be == [Place("foo"): new Token("constant-value")]);
}

unittest
{
    immutable aef = [
        Place("foo"): OutputPattern(SpecialPattern.Stdout),
    ];
    CommandResult result = { stdout: "standard output" };
    auto be = aef.apply(result);
    assert(be == [Place("foo"): new Token("standard output")]);        
}

///
unittest
{
    immutable aef = [
        Place("foo"): OutputPattern(SpecialPattern.Return),
        Place("bar"): OutputPattern("other-constant-value"),
    ];
    CommandResult result = { stdout: "standard output", code: 0 };
    auto be = aef.apply(result);
    assert(be == [
        Place("foo"): new Token("0"),
        Place("bar"): new Token("other-constant-value"),
    ]);
}

///
alias Guard = immutable InputPattern[Place];

///
alias Transition = immutable Transition_;
///
immutable abstract class Transition_
{
    ///
    abstract void fire(in BindingElement be, Tid networkTid, Logger logger);

    ///
    BindingElement fireable(Store)(in Store s) pure
    {
        Token[Place] tokenElems;
        foreach(place, ipattern; guard.byPair)
        {
            if (auto tokens = place in s.state)
            {
                auto rng = (*tokens)[].find!(t => ipattern.match(t));
                if (!rng.empty)
                {
                    tokenElems[place] = cast()rng.front;
                }
                else
                {
                    return null;
                }
            }
            else
            {
                return null;
            }
        }
        return new BindingElement(tokenElems.assumeUnique);
    }

    ///
    this(in Guard g, in ArcExpressionFunction aef) pure
    {
        guard = g;
        arcExpFun = aef;
    }

    Guard guard;
    ArcExpressionFunction arcExpFun;
}

///
alias ShellCommandTransition = immutable ShellCommandTransition_;

///
immutable class ShellCommandTransition_: Transition
{
    ///
    this(string cmd, in Guard guard, in ArcExpressionFunction aef) pure
    in(!cmd.empty)
    do
    {
        super(guard, aef);
        command = cmd;
    }

    ///
    override void fire(in BindingElement be, Tid networkTid, Logger logger = sharedLog)
    {
        logger.info("start.");
        scope(failure) logger.critical("unintended failure");

        auto needStdout = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Stdout);
        if (needStdout)
        {
            send(networkTid, "stdout is not yet supported");
            return;
        }
        // TODO: output file name should be random
        auto sout = needStdout ? File("stdout", "w") : stdout;
        scope(exit) if (needStdout) sout.name.remove;

        auto needStderr = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Stderr);
        if (needStderr)
        {
            send(networkTid, "stderr is not yet supported");
            return;
        }
        // TODO: output file name should be random
        auto serr = needStderr ? File("stderr", "w") : stderr;
        scope(exit) if (needStderr) serr.name.remove;
        
        auto needReturn = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Return);

        auto cmd = commandWith(be);
        auto pid = spawnShell(cmd, stdin, sout, serr);

		spawn((shared Pid pid) {
            // Note: if interrupted, it returns negative number
			auto code = wait(cast()pid);
			send(ownerTid, code);
		}, cast(shared)pid);

        auto result2BE(int code)
        {
            CommandResult result;
            result.code = code;
            if (needStdout)
            {
                result.stdout = sout.name;
            }
            if (needStderr)
            {
                result.stderr = serr.name;
            }
            return arcExpFun.apply(result);
        }

        receive(
            (int code) {
                auto ret = result2BE(code);
                if (needReturn || code == 0)
                {
                    logger.info("success.");
                    send(networkTid,
                         TransitionSucceeded(ret));
                }
                else
                {
                    logger.info("failure.");
                    send(networkTid,
                         TransitionFailed(be));
                }
            },
            (in SignalSent sig) {
                import core.sys.posix.signal: SIGINT;

                kill(pid, SIGINT);
                receiveOnly!int;
                logger.info("interrupted.");
                send(networkTid,
                     TransitionFailed(be));
            },
            (Variant v) {
                import core.sys.posix.signal: SIGINT;
                import core.exception: AssertError;

                logger.info("unknown message.");

                // Unintended object
                kill(pid, SIGINT);
                receiveOnly!int;
                send(networkTid,
                     new immutable AssertError("Unintended object: "~v.to!string));
            }
        );
        assert(tryWait(pid).terminated);
    }

    version(Posix)
    unittest
    {
        auto sct = new ShellCommandTransition("true", Guard.init,
                                              ArcExpressionFunction.init);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionSucceeded ts) {
                assert(ts.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
    }

    version(Posix)
    unittest
    {
        auto sct = new ShellCommandTransition("false", Guard.init,
                                              ArcExpressionFunction.init);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionFailed tf) {
                assert(tf.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
    }

    ///
    version(Posix)
    unittest
    {
        immutable aef = [
            Place("foo"): OutputPattern(SpecialPattern.Return),
        ];
        auto sct = new ShellCommandTransition("true", Guard.init, aef);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionSucceeded ts) {
                assert(ts.tokenElements == [Place("foo"): new Token("0")]);
            },
            (Variant v) { assert(false, "Caught: "~v.to!string); },
        );
    }

    version(none)
    unittest
    {
        immutable aef = [
            Place("foo"): OutputPattern(SpecialPattern.Stdout),
        ];
        auto sct = new ShellCommandTransition("echo bar", Guard.init, aef);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionSucceeded ts) {
                assert(ts.tokenElements == [Place("foo"): new Token("bar")]);
            },
            (Variant v) { assert(false, v.to!string); },
        );
    }

    version(Posix)
    unittest
    {
        import core.sys.posix.signal: SIGINT;

        immutable aef = [
            Place("foo"): OutputPattern(SpecialPattern.Return),
        ];
        auto sct = new ShellCommandTransition("sleep infinity", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid);
        send(tid, SignalSent(SIGINT));
        auto received = receiveTimeout(30.seconds,
            (TransitionFailed tf) {
                assert(tf.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
        assert(received);
    }
private:
    string commandWith(in BindingElement be) const pure
    {
        return be.tokenElements.byPair.fold!((acc, p) {
            return acc.replace(format!"#{%s}"(p.key), p.value.to!string);
        })(command);
    }

    unittest
    {
        auto t = new ShellCommandTransition("echo #{foo}", Guard.init,
                                            ArcExpressionFunction.init);
        auto be = new BindingElement([Place("foo"): new Token("3")]);
        assert(t.commandWith(be) == "echo 3", t.commandWith(be));
    }
    string command;
}

///
Tid spawnFire(in Transition tr, in BindingElement be, Tid tid, Logger logger = sharedLog)
{
    return spawn((in Transition tr, in BindingElement be, Tid tid, shared Logger logger) {
        try
        {
            tr.fire(be, tid, cast()logger);
        }
        catch(Exception e)
        {
            send(tid, cast(shared)e);
        }
    }, tr, be, tid, cast(shared)logger);
}
/+
void fire(Transition tr, BindingElement be)
{
    sigset_t ss;
    sigemptyset(&ss);
    // sigint, sighup, sigterm
    enforce(sigaddset(&ss, SIGINT));
    enforce(sigprocmask(SIG_BLOCK, &ss, null));

    // tr.isOneShot == true
    auto tid = spawn((shared Transition t, shared BindingElement b) {
        (cast()t).fire(cast()b, ownerTid);
    }, cast(shared)tr, cast(shared)be);
    auto signalHandler = spawn((sigset_t ss) {
        int signo;

        enforce(sigwait(&ss, &signo));
        send(ownerTid, new SignalSent(signo));
        receiveOnly!int; // SystemExit message
    }, ss);
    scope(exit) {
        // send exit message
        // it may already exited.
        send(signalHandler, 0);
    }
    receive(
        (in BindingElement be) {
            // nop
        },
        (in SignalSent ss) {
            send(tid, ss);
            // SS 時には何も返さないかもしれない
            //auto ret = receiveOnly!BindingElement;
        },
        (Variant v) { assert(false); },
    );
}
+/
