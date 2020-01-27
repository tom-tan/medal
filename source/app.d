import std.stdio;
import dyaml;

void main()
{
    writeln("Edit source/app.d to start your project.");
    auto root = Loader.fromFile("examples/simple.yml").load;
    foreach(Node action; root["action-creator"]) 
    {
        writeln(action["name"].as!string);
    }
}
