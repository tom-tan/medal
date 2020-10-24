module medal.network;

import medal.transition;

import std;

///
alias InvocationTransition = immutable InvocationTransition_;
///
immutable class InvocationTransition_: Transition
{
    ///
    this(in Guard g1, in Guard g2, in Transition[] trs) pure
    in(!trs.empty)
    do 
    {
        super(g1, null);
        transitions = trs;
        port = new PortTransition(g2);
    }

    ///
    override void fire(in BindingElement initBe, Tid networkTid)
    {
        auto trs = transitions~port;
        auto engine = new Engine(trs);
        engine.run(initBe, networkTid);
    }

    Transition[] transitions;
    PortTransition port;
}

///
alias PortTransition = immutable PortTransition_;
///
immutable class PortTransition_: Transition
{
    this(in Guard g) pure
    {
        super(g, null);
    }

    override void fire(in BindingElement be, Tid networkTid) const
    {
        send(networkTid, new PortSent(be));
    }
}

///
alias PortSent = immutable PortSent_;
///
immutable class PortSent_
{
    ///
    this(in BindingElement be)
    {
        bindingElement = be;
    }

    const BindingElement bindingElement;
}

unittest
{
    spawn({
        auto aef = new ArcExpressionFunction([
            Place("bar"): OutputPattern(SpecialPattern.Return),
        ]);
        auto g = new Guard(cast(immutable)[
            Place("foo"): new InputPattern(SpecialPattern.Any),
        ]);
        auto sct = new ShellCommandTransition("echo #{foo}", g, aef);
        Transition[] trs = [sct];
        auto portGuard = new Guard(cast(immutable)[
            Place("bar"): new InputPattern(SpecialPattern.Any),
        ]);
        auto net = new InvocationTransition(g, portGuard, trs);
        net.fire(new BindingElement([Place("foo"): new Token("yahoo")]), ownerTid);
    });
    receive(
        (in BindingElement be) {
            assert(be == [Place("bar"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
}

///
class Engine
{
    ///
    this(in Transition[] trs)
    in(!trs.empty)
    do
    {
        transitions = trs;
        store = new Store(trs);
        rule = new Rule(trs);
    }

    ///
    void run(in BindingElement initBe, Tid networkTid)
    {
        auto running = true;
        send(thisTid, cast(immutable)initBe);
        while(running)
        {
            receive(
                (in BindingElement be) {
                    store.put(be);
                    foreach(tr; rule.transitions)
                    {
                        if (auto nextBe = cast(immutable)tr.fireable(store))
                        {
                            store.remove(nextBe);
                            spawn((in Transition t, immutable BindingElement be) => t.fire(be, ownerTid),
                                  tr, nextBe);

                        }
                    }
                },
                (in SignalSent sig) {
                    // send sig to all transitions
                    running = false;
                },
                (in PortSent p) {
                    // send sig? to all transitions
                    send(networkTid, p.bindingElement);
                    running = false;
                },
                (Variant v) {
                    running = false;
                },
            );
        }
    }

    Transition[] transitions;
    Store store;
    Rule rule;
}

class Store
{
    this(in Transition[] trs) pure
    {
    }

    ///
    void put(in BindingElement be) pure
    //in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    do
    {
        foreach(p, t; be.tokenElements)
        {
            auto tokens = state.get(p, []);
            state[p] = tokens ~ t;
        }
    }

    ///
    void remove(in BindingElement be)
    in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    in(be.tokenElements.byPair.all!(pt => state[pt[0]].canFind(pt[1])))
    do
    {
        foreach(p, t; be.tokenElements)
        {
            auto tokens = p in state;
            auto split = (*tokens)[].findSplit([t]);
            state[p] = split[0] ~ split[2];
        }
    }

    // `dispatch(BindingElement) const pure` needs much duplication cost...

    override string toString() const pure
    {
        return state.to!string;
    }
    const(Token)[][Place] state;
}

class Rule
{
    this(in Transition[] trs) pure
    {
        transitions = trs;
    }

    /+
    auto dispatch(Store store, BindingElement trigger) const pure
    {
        return transitions.map!(t => t.fireable(store))
                          .filter!(tuple => !tuple.isNull)
                          .map!(tuple => tuple.get)
                          .array;
        // return tuple(Transition, BindingElement)[]
    }+/

    Transition[] transitions;
}