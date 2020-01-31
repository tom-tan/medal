import std;
import dyaml;
import medal.engine;

void main()
{
    writeln("Edit source/app.d to start your project.");
    /*
    auto root = Loader.fromFile("examples/simple.yml").load;
    foreach(Node action; root["action-creator"]) 
    {
        writeln(action["name"].as!string);
    }*/
    auto pid = spawnShell("ls -l");
    auto code = wait(pid);
    writeln("end: ", code);
    writeln(thisTid);
    send(thisTid, "Hello!");
    bool running = true;
    while (running){
        import std.algorithm: canFind;
        receive((string s) {
            writeln(s);
            foreach(n; [0,1,2,3].parallel)
            {
                send(thisTid, n);
            }
        },
        (int a) {
            writeln(a);
            running = false;
        });
    }
}
