# Flutter Environment Setup Guide
### 1. Download Flutter SDK
Navigate to the official [Flutter Website](https://docs.flutter.dev/install/manual) and follow the intructions to **manually** download the Flutter SDK for you operating system.
- If on a M1/M2/M3 Macbook, download the ARM64 version

### 2. Create/Choose a Storing Folder
Create or find a folder to store the extracted SDK in. Consider creating and using a ~/development/ folder under your home directory.

### 3. Extract the SDK
Extract the SDK bundle you downloaded into the directory you want to store the Flutter SDK in.
```sh
# For Mac
unzip <sdk_zip_path> -d <destination_directory_path>

# For Windows
Expand-Archive –Path <sdk_zip_path> -Destination <destination_directory_path>

# For Linux
tar -xf <sdk_zip_path> -C <destination_directory_path>
```
For example using a **Mac**, if you downloaded the bundle for **Flutter 3.35.7** into the `~/Downloads` directory and want to store the extracted SDK in the `~/development` directory:
```sh
unzip ~/Downloads/flutter_macos_3.35.7-stable.zip -d ~/development/
```

### 4. Add Flutter to Path
Copy the absolute path to the directory that you downloaded and extracted the Flutter SDK into.

Use environmental variables to access your PATH and add Flutter:

### On Mac:
1. Open or create the Zsh environment variable:
```sh
# If it exists, open the Zsh environment variable file
open .zshrc

# If it doesn't exist create the .zshrc file
cd ~ # to navigate to your home directory (if not already there)
touch ~/.zshrc
```

2. At the end of the `.zshrc` file, use the built in use the built-in `export` command to update the `PATH` variable to include the `bin` directory of your Flutter installation.

```sh
export PATH="<path-to-sdk>/bin:$PATH"
```
For example, if you downloaded Flutter into a `development/flutter` folder inside your user directory, you'd add the following to the file:

```sh
export PATH="$HOME/development/flutter/bin:$PATH"
```
3. Save and close the `.zshrc` file you just edited.


### On Windows:
1. Navigate to the environment variables settings by pressing **`Windows`** + **`Pause`** to open the **System > About** dialog. Click **Advanced System Settings > Advanced > Environment Variables**.

2. Add the Flutter bin to your path:
- In the **User variables for (username)** section of the **Environment Variables** dialog, look for the **Path** entry.

- If the **Path** entry **exists**, double-click it.

    -  The **Edit Environment Variable** dialog should open.

        a. Double-click inside an empty row.

        b. Type the path to the bin directory of your Flutter installation.
            
        For example, if you downloaded Flutter into a `development\flutter` folder inside your user directory, you'd type the following:

        ```sh
        %USERPROFILE%\development\flutter\bin
        ```
        c. Click the Flutter entry you added to select it.
        
        d. Click **Move Up** until the Flutter entry sits at the top of the list.

        e. To confirm your changes, click **OK** three times.

- If the **Path** entry **doesn't exist**, click **New**....

    -  The **Edit Environment Variable** dialog should open.

        a. In the **Variable Name** box, type `Path`.

        b. In the **Variable Value** box, type the path to the `bin` directory of your Flutter installation.

         For example, if you downloaded Flutter into a `development\flutter` folder inside your user directory, you'd type the following:

        ```sh
        %USERPROFILE%\development\flutter\bin
        ```

        c. To confirm your changes, click **OK** three times.


### On Linux:
1. Determine your default shell. If you don't know what shell you use, check which shell starts when you open a new console window.
```sh
echo $SHELL
```

2. Add the Flutter bin to your path:
- To add the `bin` directory of your Flutter installation to your `PATH`:

    1. Expand the instructions for your default shell*, found [here](https://docs.flutter.dev/install/manual)

    2. Copy the provided command.

    3. Replace `<path-to-sdk>` with the path to your Flutter SDK install.

    4. Run the edited command in your preferred terminal with that shell.

    *This depends on the default shell of your system, determined from Step 1. For example, if your system uses `bash` you'd run the following:

    ```sh
    echo 'export PATH="<path-to-sdk>:$PATH"' >> ~/.bash_profile
    ```
    For example, if you downloaded Flutter into a `development/flutter` folder inside your user directory, you'd run the following:

    ```sh
    echo 'export PATH="$HOME/develop/flutter/bin:$PATH"' >> ~/.bash_profile
    ```

### 5. Validate Installation
Apply your changes by closing and reopening all open shell sessions in your terminal apps and IDEs.

Validate your setup by opening a new terminal and running the `flutter` and `dart` tools:
```sh
flutter --version
dart --version
```
### 6. Setting up a Target Platform

Due to the current nature of the project being an iOS-focused app, the ideal devolopment solution is to use an iOS **emulator** (a software program to imitate the functions of a phone to develop the app).

However, being as developers within the team may not have Macbooks, the following provides some possible options on how to test flutter, and properly run the app as its developed.

### Recommended Target Platforms

#### <u>iOS Emulator Using Xcode (Mac)</u>:
1. Go to the app store and download "Xcode" if not already downloaded.

2. After its downloaded, select **macOS** and **iOS** as the intended platforms and click install.

3. In VSCode, open a Flutter app project, and press `CMD + Shift + P` to open up the search bar.

4. In that search bar, search for and select `Flutter: Launch Emulator`. Then, select **iOS Simulator**. A window simulating an iPhone should now open up.

5. To try running the app on the emulator navigate to the `main.dart` file (found in the `/lib` folder), and within the "Run" play button option, click "Run Without Debugging"

6. Can stop running by clicking the stop button within the Flutter app on VSCode

#### <u>Using a Terminal (Cross-Platform)</u>:
1. Ensure Web Support is Enabled:
    - Open your terminal or command prompt.

    - Run `flutter doctor` to check if web support is enabled.

    - If not, enable it with `flutter config --enable-web`.

2. Change your directory to the root of your Flutter project using `cd your_project_name`. (In our case: `cd vivordo_health`)

3. To run your app in a Chrome browser, run:
    ```sh
    flutter run -d chrome
    ```
    








