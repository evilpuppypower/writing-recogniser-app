# Training your personal model (on your own computer)

This folder trains a small model that learns from **your** handwriting and corrections which reading of a word is right, using the "Save training data" file from the app. It's preparation for Phase 4: the app doesn't use the model yet. That waits for the GATE B report and your go-ahead.

**Privacy:** everything stays on your computer. Nothing is uploaded. The training data file contains your handwriting, so:
- keep this folder somewhere **not synced to the cloud** (for example `C:\wr-training`, not Desktop or Documents if they sync to OneDrive);
- copy the file from the tablet with a USB cable or Quick Share; don't email it or put it in a cloud folder;
- never put it in the GitHub project.

The trained model (`output\model.json`) holds only a few numbers: no handwriting and no words.

## One-time setup (about 10 minutes)

1. Install Python from https://www.python.org/downloads/ (version 3.12 or newer). In the installer, tick **"Add python.exe to PATH"**.
2. On the project's GitHub page, click **Code > Download ZIP**. Unzip it, then copy the `training` folder to `C:\wr-training` (or another folder that isn't synced).
3. Double-click **`setup.bat`** in that folder. It installs NumPy (about 15 MB) into the folder itself, then says "Done".

No graphics-card software is needed: this model trains in seconds on the processor.

## Each time you train (about 5 minutes)

1. On the tablet: **Settings > How well is it learning? > Save training data** (the box icon), and save the file.
2. Copy the file to your computer (USB cable or Quick Share).
3. Double-click **`train.bat`** and choose the file.
4. Read the report. For example:

   ```
   Words checked: 640 (85 you corrected)
   Right with the engine alone:  560
   Right with your model:        598
   Engine mistakes it fixes:     45
   Right words it makes wrong:   7

   The model helps: 38 more words right out of 640 (45 fixed, 7 made wrong).
   ```

   Each word is judged by a model that was trained without it, so the numbers are fair. The report is also saved as `output\report.txt`. Send Claude the numbers (not the training file).

If it says **"Not enough data yet"**, keep using the app and correcting misread words (about 200 words read and 20 corrected are needed), then try again.

## If something goes wrong

- **"Python isn't installed"**: install it (step 1 above, with "Add python.exe to PATH" ticked), then run `setup.bat` again.
- **"This isn't a training data file from the app"**: choose the `.zip` file saved from the app.
- **"older version of the app"**: update the app, then save the training data again.
- Anything else: copy the message and send it to Claude.

## For developers

How the model works, and what the app must compute to use it: `docs/design/rescoring-model.md`. Tests (made-up data only): from this folder, `python -m unittest`.
