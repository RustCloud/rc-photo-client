# R8 rules of the app, on top of Flutter's and the libraries' own.

# WorkManager (the backup's runs, Backup.kt) creates its Room database by reflection at process
# start: R8 kept WorkDatabase_Impl but dropped its no-argument constructor, and the app crashed
# before its first screen ("NoSuchMethodException: WorkDatabase_Impl.<init> []").
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# Workers are created by class name from WorkManager's database.
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# androidx.startup creates initializers by name from the manifest.
-keep class * extends androidx.startup.Initializer { <init>(); }
