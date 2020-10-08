module medal.task;

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
class SignalSent
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

    size_t toHash() const pure
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

    override bool opEquals(Object other) const pure
    {
        if (auto t = cast(Token)other)
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

class InputPattern
{
    Token match(Token token) const pure
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
    Token match(const CommandResult result) const pure
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
class BindingElement
{
    ///
    this(Token[Place] tokenElems) pure
    {
        tokenElements = tokenElems;
    }

    bool opEquals(const Token[Place] otherTokenElements) const
    {
        return tokenElements == otherTokenElements;
    }

    override string toString() const pure
    {
        return tokenElements.to!string;
    }

    Token[Place] tokenElements;
}

///
class ArcExpressionFunction
{
    ///
    this(OutputPattern[Place] pat)
    {
        pattern = pat;
    }

    ///
    BindingElement apply(CommandResult result) const pure
    {
        auto tokenElems = pattern.byPair.map!((kv) {
            auto place = kv.key;
            auto pat = kv.value;
            return tuple(place, pat.match(result));
        }).assocArray;
        return new BindingElement(tokenElems);
    }

    unittest
    {
        auto aef = new ArcExpressionFunction((OutputPattern[Place]).init);
        auto be = aef.apply(CommandResult.init);
        assert(be.tokenElements.empty);
    }

    unittest
    {
        auto aef = new ArcExpressionFunction([
            Place("foo"): OutputPattern("constant-value"),
        ]);
        auto be = aef.apply(CommandResult.init);
        assert(be == [Place("foo"): new Token("constant-value")]);
    }

    unittest
    {
        auto aef = new ArcExpressionFunction([
            Place("foo"): OutputPattern(SpecialPattern.Stdout),
        ]);
        CommandResult result = { stdout: "standard output" };
        auto be = aef.apply(result);
        assert(be == [Place("foo"): new Token("standard output")]);        
    }

    unittest
    {
        auto aef = new ArcExpressionFunction([
            Place("foo"): OutputPattern(SpecialPattern.Return),
            Place("bar"): OutputPattern("other-constant-value"),
        ]);
        CommandResult result = { stdout: "standard output", code: 0 };
        auto be = aef.apply(result);
        assert(be == [
            Place("foo"): new Token("0"),
            Place("bar"): new Token("other-constant-value"),
        ]);
    }

    ///
    bool need(SpecialPattern pat) const pure
    {
        return pattern.byValue.canFind!(p => p.pattern == pat);
    }

    OutputPattern[Place] pattern;
}

///
class Guard
{
    /+
    BindingElement match(State s) const
    {
    }
    +/

    InputPattern[Place] patterns;
}

/// 発火継続モデルをベースとする
/// ペトリネットの理論と実践 p.35

// Stub impl for state
alias State = Token[Place];

///
abstract class Transition
{
    ///
    abstract void fire(BindingElement be, Tid networkTid) const;

    ///
    BindingElement fireable(State)(State s) const pure
    // out(result; this.fireable(result))
    {
        Token[Place] tokenElems;
        foreach(place, ipattern; guard.patterns.byPair)
        {
            if (auto token = place in s) // or tokens?
            {
                if (auto be = ipattern.match(*token))
                {
                    tokenElems[place] = be;
                }
                else
                {
                    assert(false, "TODO");
                    // return null;
                }
            }
            else
            {
                assert(false, "TODO");
                // return null;
            }
        }
        return new BindingElement(tokenElems);
    }
    // 無限容量ネットとする
    // -> 有限容量 PN を実装する場合は outputs の検査も必要

    ///
    this(Guard g, ArcExpressionFunction aef) pure
    {
        guard = g;
        arcExpFun = aef;
    }

    Guard guard;
    ArcExpressionFunction arcExpFun;
    // string namespace?
}

///
class ShellCommandTransition: Transition
{
    ///
    this(string cmd, Guard guard, ArcExpressionFunction aef) pure
    in(!cmd.empty)
    do
    {
        super(guard, aef);
        command = cmd;
    }

    ///
    override void fire(BindingElement be, Tid networkTid) const
    {
        scope(failure) send(networkTid, "Error"); // What to be send?

        auto needStdout = arcExpFun.need(SpecialPattern.Stdout);
        // TODO: output file name should be random
        auto sout = needStdout ? File("stdout", "w") : stdout;
        scope(exit) if (needStdout) sout.name.remove;

        auto needStderr = arcExpFun.need(SpecialPattern.Stderr);
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
                send(networkTid, be);
            },
            (in SignalSent sig) {
                kill(pid, SIGINT);
                auto code = receiveOnly!int;
                auto be = result2BE(code);
                send(networkTid, be);
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
        spawn({
            auto aef = new ArcExpressionFunction([
                Place("foo"): OutputPattern(SpecialPattern.Return),
            ]);
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

    version(Posix)
    unittest
    {
        auto tid = spawn({
            auto aef = new ArcExpressionFunction([
                Place("foo"): OutputPattern(SpecialPattern.Return),
            ]);
            auto sct = new ShellCommandTransition("sleep 30", null, aef);
            sct.fire(new BindingElement((Token[Place]).init), ownerTid);
        });
        send(tid, new immutable SignalSent(SIGINT));
        auto received = receiveTimeout(5.seconds,
            (in BindingElement be) {
                assert(be == [Place("foo"): new Token((-SIGINT).to!string)]);
            },
            (Variant v) { assert(false); },
        );
        assert(received);
    }
private:
    string commandWith(BindingElement be) const pure
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
