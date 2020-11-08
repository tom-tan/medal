/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.network;

import medal.config : Config;
import medal.logger : Logger, sharedLog;
import medal.transition.core;

import std.concurrency : Tid;
import std.json : JSONValue;
import std.range : empty;

version(unittest)
shared static this()
{
    import medal.logger : LogLevel;
    sharedLog.logLevel = LogLevel.off;
}

///
immutable class NetworkTransition_: Transition
{
    ///
    this(in string name, in Guard g1, in Guard g2, in Transition[] trs,
         immutable Config con = Config.init) @nogc nothrow pure @safe
    in(!trs.empty)
    do 
    {
        super(name, g1, ArcExpressionFunction.init);
        transitions = trs;
        stopGuard = g2;
        config = con;
    }

protected:
    ///
    override void fire(in BindingElement initBe, Tid networkTid, Config con = Config.init, Logger logger = sharedLog)
    {
        import medal.engine : Engine;
        import medal.message : TransitionFailed, TransitionSucceeded;

        import std.algorithm : either;
        import std.concurrency : send;

        auto engineConfig = config.inherits(con);

        logger.info(startMsg(initBe, con));
        scope(failure) logger.critical(failureMsg(initBe, con, "internal transition failed"));
        auto engine = Engine(transitions, stopGuard);
        auto retBe = engine.run(initBe, engineConfig, logger);
        if (retBe)
        {
            logger.info(successMsg(initBe, retBe, con));
            send(networkTid, TransitionSucceeded(retBe));
        }
        else
        {
            logger.info(failureMsg(initBe, con, "internal transition failed"));
            send(networkTid, TransitionFailed(initBe));
        }
    }

private:
    JSONValue startMsg(in BindingElement be, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "start";
        ret["transition-type"] = "network";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = stopGuard.to!(string[string]);
        return ret;
    }
    
    JSONValue successMsg(in BindingElement ibe, in BindingElement obe, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "network";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = ibe.tokenElements.to!(string[string]);
        ret["out"] = obe.tokenElements.to!(string[string]);
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in Config con, in string cause = "") const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["evente"] = "end";
        ret["transition-type"] = "network";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = stopGuard.to!(string[string]);
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    Transition[] transitions;
    Guard stopGuard;
    Config config;
}

/// ditto
alias NetworkTransition = immutable NetworkTransition_;

unittest
{
    import medal.message : TransitionSucceeded;
    import medal.transition.shell : ShellCommandTransition;

    import std.concurrency : receive, thisTid;
    import std.variant : Variant;

    immutable aef = [
        Place("bar"): OutputPattern(SpecialPattern.Return),
    ];
    immutable g = [
        Place("foo"): InputPattern(SpecialPattern.Any),
    ];
    auto sct = new ShellCommandTransition("", "true ~(foo)", g, aef);
    Transition[] trs = [sct];
    immutable portGuard = [
        Place("bar"): InputPattern(SpecialPattern.Any),
    ];
    auto net = new NetworkTransition("", g, portGuard, trs);

    spawnFire(net, new BindingElement([Place("foo"): new Token("yahoo")]), thisTid);
    receive(
        (TransitionSucceeded ts) {
            assert(ts.tokenElements == [Place("bar"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
}

///
immutable class InvocationTransition_: Transition
{
    ///
    this(in string name, in Guard g, 
         immutable Place[Place] inPorts, immutable Place[Place] outPorts,
         Transition tr, immutable Config con = Config.init) @nogc nothrow pure @safe
    do 
    {
        super(name, g, ArcExpressionFunction.init);
        inputPorts = inPorts;
        outputPorts = outPorts;
        subTransition = tr;
        config = con;
    }

protected:
    ///
    override void fire(in BindingElement initBe, Tid networkTid, Config con = Config.init, Logger logger = sharedLog)
    {
        import medal.message;
        import std.concurrency: receive, send, thisTid;
        import std.variant : Variant;

        logger.trace(startMsg(initBe, con));

        auto c = config.inherits(con);

        auto portedBe = port(initBe, inputPorts);
        logger.info(inputPortMsg(initBe, portedBe, con, c));
        auto tid = spawnFire(subTransition, portedBe, thisTid, c, logger);

        receive(
            (TransitionSucceeded ts) {
                auto resultedBe = port(ts.tokenElements, outputPorts);
                logger.info(outputPortMsg(resultedBe, ts.tokenElements, con, c));
                logger.trace(successMsg(initBe, resultedBe, con));
                send(networkTid, TransitionSucceeded(resultedBe));
            },
            (TransitionFailed tf) {
                auto msg = "internal transition failed";
                logger.trace(failureMsg(initBe, con, msg));
                send(networkTid, TransitionFailed(initBe, msg));
            },
            (Variant v) {
                import std.format : format;
                auto msg = format!"unknown message (%s)"(v);
                logger.trace(failureMsg(initBe, con, msg));
                send(networkTid, TransitionFailed(initBe, msg));
            }
        );
    }

private:
    static BindingElement port(in BindingElement be, immutable Place[Place] mapping)
    {
        import std.algorithm : map;
        import std.array : assocArray, byPair;
        import std.exception : assumeUnique, enforce;
        import std.typecons : tuple;

        auto ported = be.tokenElements
                        .byPair
                        .map!((p) {
                            auto mapped = *enforce(p.key in mapping);
                            return tuple(cast()mapped, cast()p.value);
                        })
                        .assocArray;
        return new BindingElement(ported.assumeUnique);
    }

    JSONValue startMsg(in BindingElement be, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "start";
        ret["transition-type"] = "invocation";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["in-port"] = inputPorts.to!(string[string]);
        ret["out-port"] = outputPorts.to!(string[string]);
        ret["sub-transition"] = subTransition.name;
        return ret;
    }
    
    JSONValue successMsg(in BindingElement ibe, in BindingElement obe, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "invocation";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = ibe.tokenElements.to!(string[string]);
        ret["in-port"] = inputPorts.to!(string[string]);
        ret["out"] = obe.tokenElements.to!(string[string]);
        ret["sub-transition"] = subTransition.name;
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in Config con, in string cause = "") const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["evente"] = "end";
        ret["transition-type"] = "invocation";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["in-port"] = inputPorts.to!(string[string]);
        ret["out-port"] = outputPorts.to!(string[string]);
        ret["sub-transition"] = subTransition.name;
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    JSONValue inputPortMsg(in BindingElement parentBe, in BindingElement thisBe, in Config parentCon, in Config thisCon) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "port";
        ret["event"] = "one-shot";
        ret["from"] = JSONValue([
            "tag": JSONValue(parentCon.tag),
            "in": JSONValue(parentBe.tokenElements.to!(string[string])),
        ]);
        ret["to"] = JSONValue([
            "tag": JSONValue(thisCon.tag),
            "in": JSONValue(thisBe.tokenElements.to!(string[string])),
        ]);
        ret["name"] = name;
        ret["sub-transition"] = subTransition.name;
        return ret;
    }

    JSONValue outputPortMsg(in BindingElement parentBe, in BindingElement thisBe, in Config parentCon, in Config thisCon) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "port";
        ret["event"] = "one-shot";
        ret["from"] = JSONValue([
            "tag": JSONValue(thisCon.tag),
            "out": JSONValue(thisBe.tokenElements.to!(string[string])),
        ]);
        ret["to"] = JSONValue([
            "tag": JSONValue(parentCon.tag),
            "out": JSONValue(parentBe.tokenElements.to!(string[string])),
        ]);
        ret["name"] = name;
        ret["sub-transition"] = subTransition.name;
        return ret;
    }

    unittest
    {

    }

    Place[Place] inputPorts;
    Place[Place] outputPorts;
    Transition subTransition;
    Config config;
}

/// ditto
alias InvocationTransition = immutable InvocationTransition_;
