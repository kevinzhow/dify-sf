/// `report_progress` (a dify-sf extension; Dify's agent has no such tool):
/// the model shows the people following the run a preview image of its work
/// so far, with a short caption. The file is uploaded as a file of the
/// execution and announced by a `progress` event. The run never waits for
/// anyone, and the image is not put into the model's context (the request
/// prefix and the prompt cache are not affected).
library;

/// Name of the tool.
const reportProgressToolName = 'report_progress';

/// Largest preview image.
const progressImageBytes = 3 * 1024 * 1024;

/// Largest number of previews per operation (run): bounds what one run can
/// store and show (at most 20 x 3 MiB).
const progressMaxPerRun = 20;

/// Longest caption, in characters (Unicode code points).
const progressCaptionMaxChars = 200;

const reportProgressDescription =
    'Show the people following this run a preview of your work so far: an '
    'image file in the workspace (PNG, JPEG or WebP, at most 3 MiB) and a '
    'short caption (at most 200 characters). Use it at milestones, for '
    'example after a first render or a major fix, not after every step '
    '(at most 20 per run). Nobody answers: the run goes on at once, and the '
    'image is not shown to you (use view_image to look at an image).';

const reportProgressInputSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'path': {
      'type': 'string',
      'description': 'Path of the image file, relative to /workspace or absolute inside it.',
    },
    'caption': {
      'type': 'string',
      'description': 'What the image shows and where the work stands.',
    },
  },
  'required': ['path', 'caption'],
  'additionalProperties': false,
};
