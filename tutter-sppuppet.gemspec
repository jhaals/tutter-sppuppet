# -*- encoding: utf-8 -*-
Gem::Specification.new do |s|
  s.name        = 'tutter-sppuppet'
  s.version     = '1.2.5'
  s.author      = ['Johan Haals', 'Erik Dalén', 'Alexey Lapitsky']
  s.email       = ['johan.haals@gmail.com', 'dalen@spotify.com', 'alexey@spotify.com']
  s.homepage    = 'https://github.com/jhaals/tutter-sppuppet'
  s.summary     = 'Github code review without collaborator access'
  s.description = 'This tutter action let non collaborators review and merge code without having more then read access to the project'
  s.license     = 'Apache 2.0'

  s.files         = `git ls-files`.split("\n")
  s.require_paths = ['lib']

  s.required_ruby_version = '>= 1.8.7'

  s.add_runtime_dependency 'tutter'
end
