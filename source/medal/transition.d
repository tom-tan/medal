module medal.transition;

import core.sys.posix.signal;
import std;

///
enum SpecialPattern
{
    Any = "_", ///
    Stdout = "STDOUT", ///
    Stderr = "STDERR", ///
    Return = "RETURN", ///
}

///
alias SignalSent = immutable SignalSent_;
///
immutable class SignalSent_
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

// std.concurrency cannot send/receive immutable AA
// https://issues.dlang.org/show_bug.cgi?id=13930 (solved by Issue 21296)
// +1
//alias BindingElement = Token[Place];
alias BindingElement = immutable BindingElement_;
///
immutable class BindingElement_
{
    ///
    this(immutable Token[Place] tokenElems) pure
    {
        tokenElements = tokenElems;
    }

    bool opEquals(in Token[Place] otherTokenElements) const
    {
        return cast(const(Token[Place]))tokenElements == otherTokenElements;
    }

    string toString() pure
    {
        return tokenElements.to!string;
    }

    Token[Place] tokenElements;
}

///
alias ArcExpressionFunction = immutable OutputPattern[Place];

///
immutable(BindingElement) apply(ArcExpressionFunction aef, CommandResult result) pure
{
    auto tokenElems = aef.byPair.map!((kv) {
        auto place = kv.key;
        auto pat = kv.value;
        return tuple(place, pat.match(result));
    }).assocArray;
    return new BindingElement(tokenElems.assumeUnique);
}

unittest
{
    ArcExpressionFunction aef;
    auto be = aef.apply(CommandResult.init);
    assert(be.tokenElements.empty);
}

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
    abstract void fire(in BindingElement be, Tid networkTid);

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
    override void fire(in BindingElement be, Tid networkTid)
    {
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
        
        // instantiate variables using be
        // Note: do not use environment variables for BindingElement!
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
            return cast(immutable)(arcExpFun.apply(result));
        }

        receive(
            (int code) {
                auto be = result2BE(code);
                if (!be.tokenElements.empty)
                {
                    send(networkTid, be);
                }
            },
            (in SignalSent sig) {
                kill(pid, SIGINT);
                auto code = receiveOnly!int;
                auto be = result2BE(code);
                if (!be.tokenElements.empty)
                {
                    send(networkTid, be);
                }
            },
            (Variant v) {
                // Unintended message
                kill(pid, SIGINT);
                receiveOnly!int;
                assert(false);
            }
        );
        assert(tryWait(pid).terminated);
    }

    version(Posix)
    unittest
    {
        // Nothing will be sent if it is a sink transition
        spawnLinked({
            ArcExpressionFunction aef;
            auto sct = new ShellCommandTransition("true", null, aef);
            sct.fire(new BindingElement((Token[Place]).init), ownerTid);
        });
        receive(
            (LinkTerminated lt) {
                // expected
            },
            (Variant v) { assert(false); },
        );
    }

    version(Posix)
    unittest
    {
        spawn({
            immutable aef = [
                Place("foo"): OutputPattern(SpecialPattern.Return),
            ];
            auto sct = new ShellCommandTransition("true", null, aef);
            sct.fire(new BindingElement((Token[Place]).init), ownerTid);
        });
        receive(
            (in BindingElement be) {
                assert(be == [Place("foo"): new Token("0")]);
            },
            (Variant v) { assert(false); },
        );
    }

    version(none)
    unittest
    {
        spawn({
            immutable aef = [
                Place("foo"): OutputPattern(SpecialPattern.Stdout),
            ];
            auto sct = new ShellCommandTransition("echo bar", null, aef);
            sct.fire(new BindingElement((Token[Place]).init), ownerTid);
        });
        receive(
            (in BindingElement be) {
                assert(be == [Place("foo"): new Token("bar")], format("[foo:bar] is expected but %s", be));
            },
            (Variant v) { assert(false, v.to!string); },
        );
    }

    version(Posix)
    unittest
    {
        auto tid = spawn({
            immutable aef = [
                Place("foo"): OutputPattern(SpecialPattern.Return),
            ];
            auto sct = new ShellCommandTransition("sleep 30", null, aef);
            sct.fire(new BindingElement((Token[Place]).init), ownerTid);
        });
        send(tid, new SignalSent(SIGINT));
        auto received = receiveTimeout(5.seconds,
            (in BindingElement be) {
                assert(be == [Place("foo"): new Token((-SIGINT).to!string)]);
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
        auto t = new ShellCommandTransition("echo #{foo}", null, null);
        auto be = new BindingElement([Place("foo"): new Token("3")]);
        assert(t.commandWith(be) == "echo 3", t.commandWith(be));
    }
    string command;
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