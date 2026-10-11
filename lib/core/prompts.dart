/// Sentences the owner is asked to write when recording labeled samples.
/// A mix of everyday words, names, numbers and punctuation so the samples
/// cover most letters and common shapes.
library;

const samplePrompts = [
  'The quick brown fox jumps over the lazy dog.',
  'Meeting moved to Tuesday at 3:30 pm.',
  'Remember to buy milk, bread and eggs.',
  'Chapter 4 explains the main results.',
  'Please call me back before Friday.',
  'The lecture notes are on page 27.',
  'The weather is warmer than yesterday.',
  'Check the formula in section 2.1 again.',
  'We need three more samples for testing.',
  'Her handwriting is neat and easy to read.',
  'Pack my box with five dozen liquor jugs.',
  'The deadline is the end of next month.',
  'Question: why does this method work?',
  'Summarise the key points in one paragraph.',
  'The experiment took about 45 minutes.',
  'Annotate the diagram on the next slide.',
  'Good ideas often start as rough notes.',
  'Review comments before the meeting on Monday.',
  'Compare both answers and pick the best one.',
  'This argument needs a stronger example.',
  'Jackdaws love my big sphinx of quartz.',
  'Total cost: 128.50.',
  'Write the email address on the form.',
  'The results look promising so far!',
  'Highlight every word you do not know.',
  'Draw an arrow from the cause to the effect.',
  'Quiet zebras jump over fixed walls.',
  'Add a short summary at the end.',
  'Is the answer 0.75 or three quarters?',
  'Tomorrow we will review chapters 5 to 8.',
];

/// Number of samples the task 0.3 "done when" criterion asks for.
const sampleGoal = 25;
