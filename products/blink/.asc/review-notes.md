# Canvas for iPhone and iPad: App Review notes

Canvas is a read-only companion to the Canvas Mac app. It does not require an
account, sign-in credentials, a subscription, or a cloud service.

## Review without a Mac

1. Open Canvas.
2. Tap **Try sample notes** on the empty screen. If notes are already saved, open **Settings** and choose **Try sample notes** in the **About** section.
3. Browse the sample notes and workspaces, open a note, and use search.
4. Tap **Exit Samples** in the **Sample Notes** banner to return to your saved notes or connect to a Mac.

The **Sample Notes** banner stays visible while browsing and in Settings.
Sample mode uses bundled example content and
the same read-only note views as synced notes. It does not require a Mac or
Local Network permission. Sample mode does not replace cached personal notes
or change an existing pairing identity.

## Optional: pair with a Mac

Syncing personal notes requires a Mac running Canvas. The review path above
does not require access to the developer's Mac or local network.

1. Put the iPhone or iPad and the Mac on the same local network.
2. Open Canvas on the Mac.
3. Right-click its menu bar icon, then select **Mobile Access** > **Enable Mobile Access** if it is not already checked.
4. Open Canvas on the iPhone or iPad.
5. Open **Settings**, then choose **Mac** in the **Connection** section.
6. Allow Local Network access if iOS asks for permission.
7. Select the nearby Mac, then tap **Request Access**.
8. Approve the device in Canvas on the Mac.

The mobile app receives an end-to-end encrypted snapshot of the Mac's notes.
The downloaded notes remain readable offline after the Mac disconnects.
The mobile app cannot edit the Mac's notes. The Mac can revoke device access.

## Local data and permissions

Local Network permission is used to discover and connect to the Mac. The app
does not upload notes to a developer-operated service. The downloaded note
cache is excluded from device backups. The pairing identity uses
non-synchronizing Keychain storage.

To remove downloaded notes, open **Settings**, choose **Notes** in the
**On This Device** section, then tap **Remove Notes** and confirm. This removes
the mobile copy. The original files on the Mac remain unchanged.
