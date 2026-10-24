# Helper-service attribution

HelperPrompts.swift and WorkflowHelperPrompts.swift adapt literal prompts from Dify 1.17.1,
commit 8387590ace4a094de812b7847fc6a4c3a27cd52b, Copyright LangGenius, Inc.
Sources: api/core/llm_generator/prompts.py and api/core/workflow/generator/prompts/.
HelperRoutes.swift / HelperModelRuntime.swift follow controllers/console/app/generator.py,
controllers/console/app/audio.py and the installed model-plugin protocol. DSLURLImport.swift
follows app_dsl_service.py and remote_fetcher. AnnotationVectors.swift / AnnotationIndexWorker.swift
follow api/providers/vdb/vdb-weaviate/src/dify_vdb_weaviate/weaviate_vector.py,
api/core/app/features/annotation_reply/annotation_reply.py and annotation enable/disable tasks.

Dify's Apache-2.0 license with additional conditions applies to these adaptations;
see LICENSE-Dify.txt (unmodified upstream license). This port uses Swift concurrency,
a durable SQL generation/lease queue and a replaceable Weaviate boundary. It adds bounded
responses, explicit proposal/apply, SSRF-proxied imports, and retry/upgrade safeguards.
It does not copy Dify's full generator orchestrator or knowledge-retrieval subsystem.
