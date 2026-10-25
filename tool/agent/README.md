# Pinned Agent model compatibility

`model_compatibility.json` carries Dify 8387590's 37 model-name exclusions. The subject is the catalog's English label
(`label.en_US`); an omitted label falls back to the model identifier consistently in the picker, checklist/MCP and
runtime. Tool-call capability is checked separately. This UI compatibility filter is not a model quality guarantee.

Generate both runtimes after deliberately updating the pinned source:

```sh
python3 tool/agent/gen_model_compatibility.py
python3 tool/agent/gen_model_compatibility.py --check
```

The generated Dart list is shared with the dependent inline client. Keep both generated outputs in the repository
so the runtime and client cannot silently drift.
