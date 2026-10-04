#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "ros_bridge.h"

using namespace godot;

static void initialize_robomaster_gui(ModuleInitializationLevel level)
{
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE)
    {
        return;
    }
    GDREGISTER_CLASS(robomaster_gui::RosBridge);
}

static void uninitialize_robomaster_gui(ModuleInitializationLevel level)
{
}

extern "C" GDExtensionBool GDE_EXPORT robomaster_gui_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                                                  GDExtensionClassLibraryPtr library,
                                                                  GDExtensionInitialization* initialization)
{
    GDExtensionBinding::InitObject init_obj(get_proc_address, library, initialization);
    init_obj.register_initializer(initialize_robomaster_gui);
    init_obj.register_terminator(uninitialize_robomaster_gui);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
