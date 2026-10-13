#include "register_types.h"
#include "godot_soci/database.h"
#include "godot_soci/query_request.h"
#include "godot_soci/query_dispatcher.h"

#include <gdextension_interface.h>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_godot_soci(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
        GDREGISTER_CLASS(GodotSociDatabase);
        GDREGISTER_CLASS(SociQueryRequest);
        GDREGISTER_CLASS(SociQueryDispatcher);
    }
}

void uninitialize_godot_soci(ModuleInitializationLevel level) {
    (void)level;
}

extern "C" GDExtensionBool GDE_EXPORT godot_soci_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_godot_soci);
    init.register_terminator(uninitialize_godot_soci);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
