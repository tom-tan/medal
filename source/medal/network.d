module medal.network;

import medal.transition;
import medal.engine;

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
        super(g1, ArcExpressionFunction.init);
        transitions = trs;
        stopGuard = g2;
    }

    ///
    override void fire(in BindingElement initBe, Tid networkTid)
    {
        auto engine = Engine(transitions, stopGuard);
        auto retBe = engine.run(initBe);
        send(networkTid, retBe);
    }

    Transition[] transitions;
    Guard stopGuard;
}

unittest
{
    spawn({
        immutable aef = [
            Place("bar"): OutputPattern(SpecialPattern.Return),
        ];
        immutable g = [
            Place("foo"): InputPattern(SpecialPattern.Any),
        ];
        auto sct = new ShellCommandTransition("echo #{foo}", g, aef);
        Transition[] trs = [sct];
        immutable portGuard = [
            Place("bar"): InputPattern(SpecialPattern.Any),
        ];
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
