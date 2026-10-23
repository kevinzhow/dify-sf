// dify-spec: web/app/components/base/features/new-feature-panel/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// useDefaultModel: speech2text and tts have a default model.
const llm = LlmGroupServices(
  defaultModels: {
    'speech2text': (provider: 'openai', model: 'whisper-1', mode: null),
    'tts': (provider: 'openai', model: 'whisper-1', mode: null),
  },
);

Future<void> renderPanel(WidgetTester t, {bool show = true, bool isChatMode = true, bool showFileUpload = true}) =>
    render(
      t,
      NewFeaturePanel(
        show: show,
        isChatMode: isChatMode,
        disabled: false,
        onClose: () {},
        showFileUpload: showFileUpload,
      ),
      features: specDefaultFeatures,
      llm: llm,
      fill: true,
    );

void main() {
  setUp(useDifyTestTranslator);

  group('NewFeaturePanel', () {
    group('Rendering', () {
      testWidgets('should not render when show is false', (t) async {
        await renderPanel(t, show: false);
        expect(byText(r'common\.features'), findsNothing);
      });

      testWidgets('should render header with title and description when show is true', (t) async {
        await renderPanel(t);
        expect(byText(r'common\.featuresDescription'), findsOneWidget);
        expect(byText(r'common\.features'), findsWidgets);
      });
    });

    group('Chat Mode Features', () {
      testWidgets('should render conversation opener in chat mode', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.conversationOpener\.title'), findsOneWidget);
      });

      testWidgets('should render follow-up in chat mode', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.suggestedQuestionsAfterAnswer\.title'), findsOneWidget);
      });

      testWidgets('should render citation in chat mode', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.citation\.title'), findsOneWidget);
      });

      testWidgets('should render speech-to-text in chat mode when model is available', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.speechToText\.title'), findsOneWidget);
      });

      testWidgets('should render text-to-speech in chat mode when model is available', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.textToSpeech\.title'), findsOneWidget);
      });

      testWidgets('should render moderation in chat mode', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.moderation\.title'), findsOneWidget);
      });
    });

    group('File Upload', () {
      testWidgets('should render file upload in chat mode with showFileUpload', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.fileUpload\.title'), findsOneWidget);
      });

      testWidgets('should not render image upload in chat mode', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.imageUpload\.title'), findsNothing);
      });

      testWidgets('should render image upload in non-chat mode with showFileUpload', (t) async {
        await renderPanel(t, isChatMode: false);
        expect(byText(r'feature\.fileUpload\.title'), findsNothing);
        expect(byText(r'feature\.imageUpload\.title'), findsOneWidget);
      });

      testWidgets('should not render file upload when showFileUpload is false', (t) async {
        await renderPanel(t, showFileUpload: false);
        expect(byText(r'feature\.fileUpload\.title'), findsNothing);
        expect(byText(r'feature\.imageUpload\.title'), findsNothing);
      });
    });

    group('MoreLikeThis Feature', () {
      testWidgets('should not render MoreLikeThis in chat mode', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.moreLikeThis\.title'), findsNothing);
      });

      testWidgets('should not render MoreLikeThis in workflow mode', (t) async {
        await renderPanel(t, isChatMode: false);
        expect(byText(r'feature\.moreLikeThis\.title'), findsNothing);
      });
    });

    group('Annotation Reply Feature', () {
      testWidgets('should not render AnnotationReply in workflow mode', (t) async {
        await renderPanel(t);
        expect(byText(r'feature\.annotation\.title'), findsNothing);
      });
    });
  });
}
