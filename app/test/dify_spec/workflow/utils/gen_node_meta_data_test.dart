// dify-spec: web/app/components/workflow/utils/__tests__/gen-node-meta-data.spec.ts
//
// dify-sf keeps genNodeMetaData's fields where they are used: the block selector's BlockMeta (classification, sort,
// type, title), the node menus' NodeMeta (author, helpLinkUri, isUndeletable, isSingleton, isTypeFixed) and the
// checklist's NodeMeta (isStart, isRequired). Their constructors carry genNodeMetaData's defaults.
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_defaults.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/node_meta.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart' as checklist;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('genNodeMetaData', () {
    test('should generate metadata with all required fields', () {
      const block = BlockMeta(sort: 1, type: 'llm', title: 'LLM Node');
      expect(block.classification, BlockClassification.defaultGroup);
      expect(block.sort, 1);
      expect(block.type, 'llm');
      expect(block.title, 'LLM Node');
      const meta = NodeMeta();
      expect(NodeMeta.author, 'Dify');
      expect(nodeHelpLink('llm'), endsWith('/use-dify/nodes/llm'));
      expect(meta.isUndeletable, isFalse);
      expect(meta.isSingleton, isFalse);
      expect(meta.isTypeFixed, isFalse);
      const check = checklist.NodeMeta();
      expect(check.isRequired, isFalse);
      expect(check.isStart, isFalse);
    });

    test('should use custom values when provided', () {
      const block = BlockMeta(
        classification: BlockClassification.logic,
        sort: 5,
        type: 'start',
        title: 'Start',
      );
      expect(block.classification, BlockClassification.logic);
      const meta = NodeMeta(isUndeletable: true, isSingleton: true, isTypeFixed: true, helpLinkUri: 'code');
      expect(meta.helpLinkUri, 'code');
      expect(meta.isUndeletable, isTrue);
      expect(meta.isSingleton, isTrue);
      expect(meta.isTypeFixed, isTrue);
      const check = checklist.NodeMeta(isRequired: true, isStart: true);
      expect(check.isRequired, isTrue);
      expect(check.isStart, isTrue);
    });

    test('should default title to empty string', () {
      const block = BlockMeta(sort: 0, type: 'code');
      expect(block.title, '');
    });

    test('should fall back helpLinkUri to type when not provided', () {
      expect(nodeMetaOf('http-request')!.helpLinkUri, isNull);
      expect(nodeHelpLink('http-request'), endsWith('/use-dify/nodes/http-request'));
    });
  });
}
