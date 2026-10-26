part of re_editor;

typedef CodeParagraphBuilder = IParagraph Function(TextSpan span, TextStyle style, double maxWidth, int? maxLength);

abstract class IParagraph {

  double get width;
  double get height;
  double get preferredLineHeight;
  bool get trucated;
  int get length;
  int get lineCount;

  void draw(Canvas canvas, Offset offset);

  TextPosition getPosition(Offset offset);

  TextRange getWord(Offset offset);
  
  InlineSpan? getSpanForPosition(TextPosition position);

  TextRange getRangeForSpan(InlineSpan span);

  TextRange getLineBoundary(TextPosition position);

  Offset? getOffset(TextPosition position);

  List<Rect> getRangeRects(TextRange range);

}