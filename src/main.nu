#!/usr/bin/env nu

use std/log

# print avalue
def debug-value [msg: string] any -> any {
    tee { log debug $"($msg)\t($in | to json -r)" }
}

# Get the specify value by path
def insert-path [
    # List of key that define the path
    path: list
    # Value to replace
    value: any
] record -> any {
    let $src = ($in | default {})

    if ($path | is-empty) {
        $value
    } else {
        $src | upsert $path.0 (insert-path ($path | skip) $value)
    }
}


# find and replace with strict comparaison
def str-replace-exact [
    find: string
    replace: string
] {
    each {|name| if $name == $find { $replace } else { $name }}
}

# Find and replace with strict comparaison
def contain [
    # Value to compare you
    find: string
] list -> bool {
    any {|name| $name == $find}
}

# Remove the specify key
def reject-path [
    # List of key that define the path
    path: list
    # Ignore non existing path
    -i
] record -> record {
    match $path {
        [] => { null },
        [$key] => {
            $in | if $i {
                reject -i $key
            } else {
                reject $key
            }
        }
        [$key, ..$path] => {
            let $old = ($in | if $i {
                get -i $key
            } else {
                get $key
            })

            let $new = ($old | if $i {
                reject-path -i $path
            } else {
                reject-path $path
            })

            $in | update $key $new
        }
    }
}

# Parse image name and tag see https://stackoverflow.com/a/53178517
def parse-oci-name [] string -> record {
    parse -r "^(?P<name>[a-z0-9_./-]+)(?::(?P<tag>[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}))?$"
    | update cells {|v| if ($v | is-empty) { null } else {$v}}
    # set default tag name
    | default latest tag
    | get 0?
}

def build-oci-name [] nothing -> record {
    $"($in.name):($in.tag)"
}

# Parse image and exit with error message
def parse-oci-name-strict [
    # Description of the parse image name
    description: string
] string -> record {
    let $name = $in

    let $image = ($name | parse-oci-name)

    if ($image | is-empty) {
        log critical $"invalid ($description) image name: ($name)"
        exit 1
    }

    $image
}

# Create a context with a tempral directory
def with-tmpdir [
    # function to execute inside the context
    f :closure
] {
    let $tmp = mktemp -d
    log debug $"Create tmp directory: ($tmp)"

    try {
        do $f $tmp
    } catch {|err|
        log debug $"clean-up tmp directory [failed]: ($tmp)"
        ^chmod -R 700 $tmp
        rm -rf $tmp
        $err.raw
    }

    log debug $"clean-up tmp directory: ($tmp)"
    ^chmod -R 700 $tmp
    rm -rf $tmp
}

# Create context that allow to modifiy a oci
def with-tarball [
    # Path to the input tarball
    input: path
    # Path to the output tarball
    --output (-o): path
    # function to execute inside the tarball
    f: closure
] {
    with-tmpdir {|tmp|
        log info "Unpackage OCI tarball"
        let $res = (^tar -xvzf $input -C $tmp --no-same-owner | complete)
        if $res.exit_code != 0 {
            error make {msg: $"Can't uncompress tarall:\nstdout: ($res.stdout)\nstderr: ($res.stderr)", }
        }
        log debug ($res.stdout | to json)
        ^chmod -R 700 $tmp

        do $f $tmp

        # Skip if no output
        if ($output | is-empty) { return }

        log info "Package OCI tarball"
        let $res = (^tar -czvf $output -C $tmp . | complete)
        if $res.exit_code != 0 {
            error make {msg: $"Can't compress tarall:\nstdout: ($res.stdout)\nstderr: ($res.stderr)", }
        }
    }
}

# Get the specify value by path
def get-path [
    # List of key that define the path
    path: list
    # Ignore non existing path
    -i
] record -> any {
    let $root = $in
    $path | reduce -f $root {|key, obj| $obj | get -i $key}
}

# Update file content
def update-file [
    # path of the file
    path: path
    # Function to modify
    closure: closure
] {
    open -r $path | do $closure | save -f $path
}

# Update an json file content
def update-json [
    # path of the json file
    path: path
    # Function to modify
    closure: closure
] {
    update-file $path {
        from json | do $closure | to json
    }
}

# Rename an image insde a repository file
def tag-repo [
    # Name of the image inside the tarball
    old_image: record
    # New name of the image
    new_image: record
] record -> record {
    let $repo = $in

    let $old_path = [$old_image.name $old_image.tag]
    let $new_path = [$new_image.name $new_image.tag]

    let $tag = ($repo | get-path -i $old_path)
    if $tag == null {
        log critical $"Can't found tag ($old_image.tag) inside image ($old_image.name)"
        panic "critical error"
    }

    $repo | insert-path $new_path $tag
}

# Rename an image insde a repository file
def tag-meta [
    # Name of the image inside the tarball
    old_image: record
    # New name of the image
    new_image: record
] record -> record {
    let $old_name = ($old_image | build-oci-name)
    let $new_name = ($new_image | build-oci-name)

    $in | each { upsert RepoTags {
        let $src = $in
        if ($src | contain $old_name) { $src | append $new_name } else { $src }
    }}
}


# Add image new tags
def 'main image tag add' [
    input: path
    # Path to the tarball
    old_name: string
    # Name of the image inside the tarball
    ...new_names: string
    # New names of the image
    --output (-o): path
    # Path to the output tarball
] {

    log info "Parsing images name"
    let $old_image = ($old_name | parse-oci-name-strict "old")
    let $new_images = ($new_names | each { parse-oci-name-strict "new" })

    with-tarball $input --output ($output | default $input) {|tarball|
        log info $"renaming ($old_name) to ($new_names)"
        log info "Modify `repositories` file"
        update-json ($tarball | path join repositories) {
            let $src = $in
            $new_images | reduce -f $src {|new_image, acc|
                $acc | tag-repo $old_image $new_image
            } | debug-value "new repositories"
        }

        log info "Modify `manifest.json` file"
        update-json ($tarball | path join manifest.json) {
            let $src = $in
            $new_images | reduce -f $src {|new_image, acc|
                $acc | tag-meta $old_image $new_image
            } | debug-value "new manifest"
        }
    }
}

# Rename an image insde a repository file
def rename-repo [
    # Name of the image inside the tarball
    old_image: record
    # New name of the image
    new_image: record
] record -> record {
    let $repo = $in

    let $old_path = [$old_image.name $old_image.tag]
    let $new_path = [$new_image.name $new_image.tag]

    let $tag = ($repo | get-path -i $old_path)
    if $tag == null {
        log critical $"Can't found tag ($old_image.tag) inside image ($old_image.name)"
        panic "critical error"
    }

    $repo | reject-path $old_path | insert-path $new_path $tag
}

# Rename an image insde a repository file
def rename-meta [
    # Name of the image inside the tarball
    old_image: record
    # New name of the image
    new_image: record
] record -> record {
    let $old_name = ($old_image | build-oci-name)
    let $new_name = ($new_image | build-oci-name)

    $in | each { update RepoTags { str-replace-exact $old_name $new_name } }
}

# Rename image tag
def 'main image tag rename' [
    input: path
    # Path to the tarball
    old_name: string
    # Name of the image inside the tarball
    new_name: string
    # New name of the image
    --output (-o): path
    # Path to the output tarball
] {

    log info "Parsing images name"
    let $old_image = ($old_name | parse-oci-name-strict "old")
    let $new_image = ($new_name | parse-oci-name-strict "new")

    log info $"renaming ($old_name) to ($new_name)"
    with-tarball $input --output ($output | default $input) {|tarball|
        log info "Modify `repositories` file"
        update-json ($tarball | path join repositories) {
            rename-repo $old_image $new_image  | debug-value "new repositories"
        }

        log info "Modify `manifest.json` file"
        update-json ($tarball | path join manifest.json) {
            rename-meta $old_image $new_image | debug-value "new manifest"
        }
    }
}


# Delete image from repo insde a repository
def delete-repo [
    # Images to delete
    image: record
] record -> record {
    reject-path  [$image.name $image.tag]
}

# Delete image from repo insde a repository
def delete-meta [
    # Images to delete
    image: record
] record -> record {
    let $name = ($image | build-oci-name)

    $in | each { update RepoTags { where {|| $in != $name } } }
}

# Delete image tags
def 'main image tag delete' [
    input: path
    # Path to the tarball
    ...names: string
    # Names of the iamge that need to be deleted
    --output (-o): path
    # Path to the output tarball
] {
    with-tarball $input --output ($output | default $input) {|tarball|
        log info "Parsing images name"
        let $images = ($names | each { parse-oci-name-strict "to delete" })

        log info "Modify `repostiories` file"
        update-json ($tarball | path join repositories) {
            let $src = $in
            $images | reduce -f $src {|image, repo|
                $repo | delete-repo $image
            } | debug-value "new repositories"
        }

        log info "Modify `manifest.json` file"
        update-json ($tarball | path join manifest.json) {
            let $src = $in
            $images | reduce -f $src {|image, repo|
                $repo | delete-meta $image
            } | debug-value "new manifest"
        }
    }
}

# List image tags
def 'main image tag list' [
    input: path
] {
    with-tarball $input {|tarball|
        log info "parsing `manifest.json` file"
        $tarball
        | path join manifest.json
        | open
        | get RepoTags
        | flatten
        | if (is-terminal --stdout) { print } else { print -r }
    }
}

alias 'main image tag move' = main image tag rename
alias 'main image tag remove' = main image tag delete

alias 'main image tag mv' = main image tag rename
alias 'main image tag rm' = main image tag delete
alias 'main image tag ls' = main image tag list

# OCI manager
def main [ ] {
    help commands main
}

# OCI image manager
def 'main image' [ ] {
    help commands main image
}


# OCI image tag manager
def 'main image tag' [ ] {
    help commands main image tag
}
