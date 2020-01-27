module medal.engine;

///
class Engine
{
    /// 動作イメージ
    void run()
    {
        auto queue = [];
        while (!queue.empty)
        {
            auto action = queue.pop;
            foreach(com; action.commands)
            {
                com.sideeffect.run;
            }
            queue.push(action.commands.map!"c.out");
        }
    }
}
