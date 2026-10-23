# A local mail capture for the integration tests

`mail_capture.py` is the "local image" the review uses for mail: a tiny SMTP server (0.0.0.0:2525, every message
accepted and kept) and an HTTP view of what it holds (0.0.0.0:8025; `GET` lists the decoded bodies, `DELETE` empties
it). No mail leaves the machine.

```
python3 test/support/mail_capture.py &
```

Point a server of this repository at it and run the mailed-form part of `integration_test/human_input_flow_test.dart`:

```
# the server's compose: COLLAB_MAIL_SMTP_HOST=host.docker.internal, COLLAB_MAIL_SMTP_PORT=2525,
# COLLAB_MAIL_SMTP_TLS=none, COLLAB_MAIL_FROM="Dify <no-reply@example.test>", COLLAB_WEBAPP_BASE_URL=http://127.0.0.1:3000
DIFYSF_RUNTIME_URL=http://127.0.0.1:18081 DIFYSF_EMAIL=... DIFYSF_PASSWORD=... DIFYSF_MAILBOX_URL=http://127.0.0.1:8025/all \
  xvfb-run -a -s "-screen 0 1600x1000x24" flutter test integration_test/human_input_flow_test.dart -d linux
```

The test empties the capture first, so the newest link it reads is the mail of the run it started.
