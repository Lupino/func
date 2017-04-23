## Functions as a Service (FaaS)

A simple function as a service server write on haskell.

## Concept
* The `func` hosts a web server allowing a post request to be forwarded to a desired process via STDIN.
The response is sent back to the caller via STDOUT

## Quick Start Guide

This section shows you how to quickly get set up to factor.

### Install `func` executer

Install from binary release:

* [Linux x86_64](https://github.com/Lupino/func/releases/download/v0.1/func_linux_x86_64.gz)
* [Mac OS x86_64](https://github.com/Lupino/func/releases/download/v0.1/func_maxos_x86_64.gz)

Or build from source:

    git clone https://github.com/Lupino/func.git
    cd func
    stack install

### Run you own `func` instance

Make sure the `func` command is in you `PATH`.

    func -c config.yaml

Request `cat` function

    curl http://127.0.0.1:3000/function/cat -d "Hello World!"

### Write a new function

Open a file called `myfunc.go` then write sub code:

```golang
package main

import (
    "fmt"
    "io/ioutil"
    "log"
    "os"
)

func main() {
    input, err := ioutil.ReadAll(os.Stdin)
    if err != nil {
        log.Fatalf("Unable to read standard input: %s", err.Error())
    }
    fmt.Println(string(input))
}
```

Compile with command `go build -o myfunc`

Add the sub config to `config.yaml`

```yaml
- func: myfunc
  proc: myfunc
```

Use sign `HUP` to reload `func`

```bash
ps aux | grep func
# got the pid and send `HUP` sign
kill -HUP pid
```

Test `myfunc`

```bash
curl http://127.0.0.1:3000/function/myfunc -d "Hello World!"
```

More example please see [sample-functions](https://github.com/Lupino/func/tree/master/sample-functions)

## Config reference

```yaml
- func: func       # function name.
  proc: proc       # command or command file path.
  argv: []         # process arguments (optional).
  content-type: "" # Response content type (optional).
```
