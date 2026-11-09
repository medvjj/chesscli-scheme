# chesscli-scheme

**chesscli-scheme** is a terminal-based chess engine controller written in GNU Guile Scheme. It communicates with a UCI-compatible chess engine and provides a simple command-line interface for running engine games, choosing search limits, and viewing position evaluations.

The current configuration is set up for Stockfish 19, using the executable name `sf19`.

## Features

- Control a UCI chess engine from a terminal.
- Configure the engine's **Threads** and **Hash** options at startup.
- Choose one of three search modes:
  1. **Fixed depth** — search to a specified depth.
  2. **Time per move + increment** — give each move a fixed base time and maintain a separate increment reserve for White and Black.
  3. **Game clock + increment** — give each side a total game-time allowance and add a fixed increment after every move.
- Start from the standard chess position or provide a custom position in FEN format.
- Display search depth, evaluation in pawns, mate information, and the principal variation (PV).
- Start and stop a game from the command prompt.
- Save session information and moves to `chess-session.log`.

## Requirements

- A Linux system with a terminal.
- GNU Guile Scheme **3.0** (recommended; older versions have not been tested).
- Stockfish 19, or another UCI-compatible engine that supports the options and commands used by the program.
- Permission to execute the chess engine binary.

The program uses Guile's standard modules. No additional third-party Scheme packages are required.

### Supported / intended Linux distributions

The project is intended for terminal use on Linux distributions such as:

- Debian
- Manjaro
- Gentoo
- Rocky Linux

The installation commands below are starting points. Package names and repository availability may vary by distribution release.

#### Debian

```sh
sudo apt update
sudo apt install guile-3.0
```

#### Manjaro

```sh
sudo pacman -Syu
sudo pacman -S guile
```

#### Gentoo

```sh
sudo emerge --ask dev-scheme/guile
```

#### Rocky Linux

On Rocky Linux, enable the repository that provides Guile if it is not already enabled. On releases where the `guile30` package is available:

```sh
sudo dnf install epel-release
sudo dnf install guile30
```

Check the package name for your Rocky Linux release if `guile30` is not found.

### Check the Guile installation

After installing Guile, verify that it is available:

```sh
guile --version
```

GNU Guile 3.0 is the recommended version for this project.

## Install the chess engine

The current source code expects the engine executable at this exact path:

```text
$HOME/guile_scheme_programms/chesscli/sf19
```

Create the directory:

```sh
mkdir -p "$HOME/guile_scheme_programms/chesscli"
```

Place the Stockfish 19 executable in that directory and name it `sf19`. Then make it executable:

```sh
chmod +x "$HOME/guile_scheme_programms/chesscli/sf19"
```

The engine is **not included** in this repository. Download and install Stockfish separately, and follow its license and distribution terms.

If your engine is installed somewhere else, edit the `engine-path` definition near the beginning of `chesscli_time_controls.scm` to point to the correct executable.

## Get the program

Clone the repository:

```sh
git clone https://github.com/USERNAME/chesscli-scheme.git
cd chesscli-scheme
```

Replace `USERNAME` with your GitHub username or organization name.

## Run

Run the program from a terminal:

```sh
guile chesscli_time_controls.scm
```

At startup, the program:

1. Connects to the engine at the configured path.
2. Asks for the number of engine threads and the Hash size in MB.
3. Asks you to choose a search mode and enter its parameters.
4. Asks for an initial FEN position. Press **Enter** to use the standard starting position.
5. Waits for a command.

## Search modes

### 1. Fixed depth

Choose a search depth, for example `10`. The engine searches to the requested depth for each move.

### 2. Time per move + increment

Set a base time per move and an increment in seconds.

For example, with a base time of 10 seconds and an increment of 2 seconds:

- Each move starts with the 10-second base allowance.
- White and Black have separate increment reserves.
- The increment is added to the moving side's reserve after each move.
- If a search takes longer than the base allowance, the excess is deducted from that side's reserve.

This mode keeps the base time fixed while allowing unused increment time to accumulate as a reserve.

### 3. Game clock + increment

Set the initial clock time for each side and the increment in seconds.

For example, with 600 seconds and a 3-second increment:

- White starts with 600 seconds.
- Black starts with 600 seconds.
- The time spent on a move is deducted from that side's clock.
- The increment is added after that side completes a move.

This mode behaves like a conventional chess clock with a per-move increment.

## Commands

Once the program is ready, use these commands:

| Command | Action |
| --- | --- |
| `p` | Start a game / engine move calculation. |
| `s` | Stop the active game or search. |
| `q` | Quit the program. |

## Session log

The program appends session information and recorded moves to:

```text
chess-session.log
```

The log is created in the current working directory — the directory from which you launch the program.

## Repository layout

A minimal repository can look like this:

```text
chesscli-scheme/
├── README.md
└── chesscli_time_controls.scm
```

Do not commit the engine executable or generated session logs unless you have a specific reason and the relevant redistribution rights.

## AI Assistance

ChatGPT (OpenAI) was used as an AI-assisted development tool during this project's development. It helped with code modifications, debugging, feature implementation, and documentation.

The project requirements, design decisions, feature selection, and testing were directed and reviewed by the project author.

## Notes and limitations

- The program is designed for terminal use; it does not provide a graphical interface.
- The engine path is currently hard-coded in the source file.
- The program communicates with the engine using the Universal Chess Interface (UCI) protocol.
- Stockfish is a separate project and is not bundled with this program.
- The project license has not yet been selected. Add a `LICENSE` file before publishing if you want to specify how others may use, modify, and redistribute your code.

## License

No license has been selected for this project yet. Until a license is added, the default copyright rules apply. Choose a license and add its full text in a `LICENSE` file before inviting reuse or contributions.