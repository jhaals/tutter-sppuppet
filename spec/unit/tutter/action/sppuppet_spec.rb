require 'spec_helper'
require 'json'

describe 'tutter Sppuppet action' do
  it 'should post a comment with instructions' do
    data = IO.read('spec/fixtures/new_issue.json')
    post '/', data, 'HTTP_X_GITHUB_EVENT' => 'opened'
    expect { last_response.body match(/To merge at least/) }
    expect { last_response.status == 200 }
  end
end
