# tutter-sppuppet

This action lets non-collaborators review and merge code without having push access to the project.

Here's how it works:

1. A pull request get submitted
2. Someone reviews it and adds a _+1_ comment
3. Another person comments _+1_
4. The pull request can be merged by commenting _!merge_ when it has the
desired amount of +1's(configurable, defaults to 1)

A pull request will be blocked if it has a _-1_ comment

## Installation

    gem install tutter-sppuppet

sppuppet specific settings (goes into tutter.yaml)

    action: 'sppuppet'
    action_settings:
      plus_ones_required: 3
      post_instructions: true
      instructions: 'To merge, post 3 +1s and then !merge'
      generate_reports = true
      reports_dir = '/var/lib/tutter/reports'

### TODO
* whitelist
* blacklist
* tests
