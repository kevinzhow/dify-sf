ARG DAEMON_BASE
FROM ${DAEMON_BASE}
COPY --chmod=444 reasoning.py sitecustomize.py /opt/dify-sf/model-compat/
# Preserve the distribution's existing hook. This additive image layer is
# inherited by virtualenvs without weakening the daemon's environment allowlist.
RUN python3 - <<'PY'
from pathlib import Path
import shutil, sysconfig
hook = Path(sysconfig.get_path('stdlib')) / 'sitecustomize.py'
if hook.exists():
    shutil.copyfile(hook, '/opt/dify-sf/model-compat/original-sitecustomize.py')
with hook.open('a') as target:
    target.write("\n# dify-sf host reasoning compatibility\nexec(compile(open('/opt/dify-sf/model-compat/sitecustomize.py', 'rb').read(), '/opt/dify-sf/model-compat/sitecustomize.py', 'exec'))\n")
PY

# COPY --chmod also affects directories it creates; workers need traversal.
RUN chmod 0555 /opt/dify-sf /opt/dify-sf/model-compat
