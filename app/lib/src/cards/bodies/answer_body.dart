import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../design/dify_tokens.g.dart';
import '../card_kit.dart';
import '../node_body.dart';

/// Answer (nodes/answer/node.tsx): an InfoPanel titled "Answer" with the answer text and its variable chips.
class AnswerBody extends NodeBody {
  const AnswerBody();

  // Card 240 - border 2 - px-3 24 - InfoPanel px-1.25 10.
  static const contentWidth = 204.0;

  String _answer(BodyContext ctx) => ctx['answer'] is VString ? (ctx['answer']! as VString).value : '';

  @override
  double height(BodyContext ctx) {
    final content = InlineVarText(_answer(ctx), ctx).height(contentWidth);
    // mb-1 + py-1 + InfoPanel (py-0.75 x 2 + title 12 + gap-y-0.5 + content).
    return 4 + 4 + 3 + 12 + 2 + content + 3 + 4;
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final text = InlineVarText(_answer(ctx), ctx);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: DifyColors.workflowBlockParmaBg,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DifyText('Answer', DifyType.system2xsSemiboldUppercase, color: DifyColors.textSecondary),
            const SizedBox(height: 2),
            text.build(),
          ],
        ),
      ),
    );
  }
}
