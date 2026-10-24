from dify_plugin import Plugin, DifyPluginEnv
from dify_plugin.core.entities.plugin.request import PluginInvokeType, ToolActions

plugin = Plugin(DifyPluginEnv())
# SDK 0.10.2 retains this deprecated executor but no longer registers its route.
# This fixture explicitly supplies the legacy route to verify hosts that still use it.
# Ordinary dynamic-select requests use the SDK's unmodified registered route.
plugin.register_route(
    plugin.plugin_executer.get_tool_runtime_parameters,
    lambda data: data.get('type') == PluginInvokeType.Tool.value
    and data.get('action') == ToolActions.GetToolRuntimeParameters.value,
)

if __name__ == '__main__':
    plugin.run()
