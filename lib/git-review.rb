# Octokit is used to access GitHub's API.
require 'octokit'
# Launchy is used in 'browse' to open a browser.
require 'launchy'
# Time is used to parse time strings from git back into Time objects.
require 'time'

class GitReview

  ## COMMANDS ##

  # List all pending requests.
  def list
    @pending_requests.reverse! if @args.shift == '--reverse'
    output = @pending_requests.collect do |pending_request|
      # Find only pending (= unmerged) requests and output summary. GitHub might
      # still think of them as pending, as it doesn't know about local changes.
      next if merged?(pending_request['head']['sha'])
      line = format_text(pending_request['number'], 8)
      date_string = format_time(pending_request['updated_at'])
      line << format_text(date_string, 11)
      line << format_text(pending_request['comments'], 10)
      line << format_text(pending_request['title'], 91)
      line
    end
    if output.compact.empty?
      puts "No pending requests for '#{source}'"
      return
    end
    puts "Pending requests for '#{source}'"
    puts 'ID      Updated    Comments  Title'
    puts output.compact
  end

  # Show details for a single request.
  def show
    return unless request_exists?
    option = @args.shift == '--full' ? '' : '--stat '
    sha = @pending_request['head']['sha']
    puts "ID        : #{@pending_request['number']}"
    puts "Label     : #{@pending_request['head']['label']}"
    puts "Updated   : #{format_time(@pending_request['updated_at'])}"
    puts "Comments  : #{@pending_request['comments']}"
    puts
    puts @pending_request['title']
    puts
    puts @pending_request['body']
    puts
    puts git_call("diff --color=always #{option}HEAD...#{sha}")
    puts
    puts "Progress  :"
    puts
    discussion
  end

  # Open a browser window and review a specified request.
  def browse
    Launchy.open(@pending_request['html_url']) if request_exists?
  end

  # Checkout a specified request's changes to your local repository.
  def checkout
    return unless request_exists?
    create_local_branch = @args.shift == '--branch' ? '' : 'origin/'
    puts 'Checking out changes to your local repository.'
    puts 'To get back to your original state, just run:'
    puts
    puts '  git checkout master'
    puts
    git_call "checkout #{create_local_branch}#{@pending_request['head']['ref']}"
  end

  # Accept a specified request by merging it into master.
  def merge
    return unless request_exists?
    option = @args.shift
    unless @pending_request['head']['repository']
      # Someone deleted the source repo.
      user = @pending_request['head']['user']['login']
      url = @pending_request['patch_url']
      puts "Sorry, #{user} deleted the source repository, git-review doesn't support this."
      puts 'You can manually patch your repo by running:'
      puts
      puts "  curl #{url} | git am"
      puts
      puts 'Tell the contributor not to do this.'
      return false
    end
    message = "Accept request ##{@pending_request['number']} and merge changes into \"#{target}\""
    exec_cmd = "merge #{option} -m '#{message}' #{@pending_request['head']['sha']}"
    puts
    puts 'Request title:'
    puts "  #{@pending_request['title']}"
    puts
    puts 'Merge command:'
    puts "  git #{exec_cmd}"
    puts
    puts git_call(exec_cmd)
  end

  # Close a specified request.
  def close
    return unless request_exists?
    Octokit.post("issues/close/#{source_repo}/#{@pending_request['number']}")
    puts 'Successfully closed request.' unless request_exists?(@pending_request['number'])
  end

  # Prepare local repository to create a new request.
  # Sets @local_branch.
  def prepare
    # People should work on local branches, but especially for single commit changes,
    # more often than not, they don't. Therefore we create a branch for them,
    # to be able to use code review the way it is intended.
    if source_branch == target_branch
      # Unless a branch name is already provided, ask for one.
      if (branch_name = @args.shift).nil?
        puts 'Please provide a name for the branch:'
        branch_name = gets.chomp.gsub(/\W+/, '_').downcase
      end
      # Create the new branch (as a copy of the current one).
      @local_branch = "review_#{Time.now.strftime("%y%m%d")}_#{branch_name}"
      git_call "checkout -b #{@local_branch}"
      if source_branch == @local_branch
        # Stash any uncommitted changes.
        git_call('stash') if (save_uncommitted_changes = !git_call('diff HEAD').empty?)
        # Go back to master and get rid of pending commits (as these are now on the new branch).
        git_call "checkout #{target_branch}"
        git_call "reset --hard origin/#{target_branch}"
        git_call "checkout #{@local_branch}"
        git_call('stash pop') if save_uncommitted_changes
      end
    else
      @local_branch = source_branch
    end
  end

  # Create a new request.
  # TODO: Support creating requests to other repositories and branches (like the original repo, this has been forked from).
  def create
    # Prepare @local_branch.
    prepare
    # Don't create request with uncommitted changes in current branch.
    unless git_call('diff HEAD').empty?
      puts 'You have uncommitted changes. Please stash or commit before creating the request.'
      return
    end
    unless git_call("cherry #{target_branch}").empty?
      # Push latest commits to the remote branch (and by that, create it if necessary).
      git_call "push --set-upstream origin #{@local_branch}"
      # Gather information.
      last_request_id = @pending_requests.collect{|req| req['number'] }.sort.last.to_i
      title = "[Review] Request from '#{git_config['github.login']}' @ '#{source}'"
      # TODO: Insert commit messages (that are not yet in master) into body (since this will be displayed inside the mail that is sent out).
      body = 'Please review the following changes:'
      # Create the actual pull request.
      Octokit.create_pull_request(target_repo, target_branch, source_branch, title, body)
      # Switch back to target_branch and check for success.
      git_call "checkout #{target_branch}"
      update
      potential_new_request = @pending_requests.find{ |req| req['title'] == title }
      if potential_new_request and potential_new_request['number'] > last_request_id
        puts 'Successfully created new request.'
      end
    else
      puts 'Nothing to push to remote yet. Commit something first.'
    end
  end

  # Start a console session (used for debugging).
  def console
    puts 'Entering debug console.'
    request_exists?
    require 'ruby-debug'
    Debugger.start
    debugger
    puts 'Leaving debug console.'
  end


  private

  # Setup variables and call actual commands.
  def initialize(args)
    command = args.shift
    if command and self.respond_to?(command)
      @user, @repo = repo_info
      return if @user.nil? or @repo.nil?
      @args = args
      return unless configure_github_access
      update
      self.send command
    else
      unless command.nil? or command.empty? or %w(help -h --help).include?(command)
        puts "git-review: '#{command}' is not a valid command.\n\n"
      end
      help
    end
  end

  # Show a quick reference of available commands.
  def help
    puts 'Usage: git review <command>'
    puts 'Manage review workflow for projects hosted on GitHub (using pull requests).'
    puts
    puts 'Available commands:'
    puts '  list [--reverse]          List all pending requests.'
    puts '  show <ID> [--full]        Show details for a single request.'
    puts '  browse <ID>               Open a browser window and review a specified request.'
    puts '  checkout <ID> [--branch]  Checkout a specified request\'s changes to your local repository.'
    puts '  merge <ID>                Accept a specified request by merging it into master.'
    puts '  close <ID>                Close a specified request.'
    puts '  prepare                   Creates a new local branch for a request.'
    puts '  create                    Create a new request.'
  end

  # Check existence of specified request and assign @pending_request.
  def request_exists?(request_id = nil)
    # NOTE: If request_id is set explicitly we might need to update to get the
    # latest changes from GitHub, as this is called from within another method.
    automated = !request_id.nil?
    update if automated
    request_id ||= @args.shift.to_i
    if request_id == 0
      puts 'Please specify a valid ID.'
      return false
    end
    @pending_request = @pending_requests.find{ |req| req['number'] == request_id }
    if @pending_request.nil?
      # No output for automated checks.
      puts "Request '#{request_id}' does not exist." unless automated
      return false
    end
    true
  end

  # Get latest changes from GitHub.
  def update
    @pending_requests = Octokit.pull_requests(source_repo)
    repos = @pending_requests.collect do |req|
      repo = req['head']['repository']
      "#{repo['owner']}/#{repo['name']}" unless repo.nil?
    end
    repos.uniq.compact.each do |repo|
      git_call("fetch git@github.com:#{repo}.git +refs/heads/*:refs/pr/#{repo}/*")
    end
  end

  # System call to 'git'.
  def git_call(command, verbose = debug_mode)
    if verbose
      puts
      puts "  git #{command}"
      puts
    end
    output = `git #{command}`
    puts output if verbose and not output.empty?
    output
  end

  # Show current discussion for @pending_request.
  def discussion
    request = Octokit.pull_request(source_repo, @pending_request['number'])
    result = request['discussion'].collect do |entry|
      output = "\e[35m#{entry["user"]["login"]}\e[m "
      case entry['type']
        # Comments:
        when "IssueComment", "CommitComment", "PullRequestReviewComment"
          output << "added a comment"
          output << " to \e[36m#{entry['commit_id'][0..6]}\e[m" if entry['commit_id']
          output <<  " on #{format_time(entry['created_at'])}"
          unless entry['created_at'] == entry['updated_at']
            output << " (updated on #{format_time(entry['updated_at'])})"
          end
          output << ":\n#{''.rjust(output.length + 1, "-")}\n"
          output << "> \e[32m#{entry['path']}:#{entry['position']}\e[m\n" if entry['path'] and entry['position']
          output << entry['body']
        # Commits:
        when "Commit"
         output << "authored commit \e[36m#{entry['id'][0..6]}\e[m on #{format_time(entry['authored_date'])}"
         unless entry['authored_date'] == entry['committed_date']
           output << " (committed on #{format_time(entry['committed_date'])})"
         end
         output << ":\n#{''.rjust(output.length + 1, "-")}\n#{entry["message"]}"
      end
      output << "\n\n\n"
    end
    puts result.compact unless result.empty?
  end

  # Display helper to make output more configurable.
  def format_text(info, size)
    info.to_s.gsub("\n", ' ')[0, size-1].ljust(size)
  end

  # Display helper to unify time output.
  def format_time(time_string)
    Time.parse(time_string).strftime('%d-%b-%y')
  end

  # Returns a string that specifies the source repo.
  def source_repo
    "#{@user}/#{@repo}"
  end

  # Returns a string that specifies the source branch.
  def source_branch
    git_call('branch').chomp!.match(/\*(.*)/)[0][2..-1]
  end

  # Returns a string consisting of source repo and branch.
  def source
    "#{source_repo}/#{source_branch}"
  end

  # Returns a string that specifies the target repo.
  def target_repo
    # TODO: Enable possibility to manually override this and set arbitrary repositories.
    source_repo
  end

  # Returns a string that specifies the target branch.
  def target_branch
    # TODO: Enable possibility to manually override this and set arbitrary branches.
    'master'
  end

  # Returns a string consisting of target repo and branch.
  def target
    "#{target_repo}/#{target_branch}"
  end

  # Returns a boolean stating whether a specified commit has already been merged.
  def merged?(sha)
    not git_call("rev-list #{sha} ^HEAD 2>&1").split("\n").size > 0
  end

  # Uses Octokit to access GitHub.
  def configure_github_access
    if git_config['github.login'] and git_config['github.password']
      Octokit.configure do |config|
        config.api_version = 2
        config.login = git_config['github.login']
        config.password = git_config['github.password']
      end
      true
    else
      puts 'Please update your git config and provide your GitHub login and password.'
      puts
      puts '  git config --global github.login your_github_login_1234567890'
      puts '  git config --global github.password your_github_password_1234567890'
      puts
      false
    end
  end

  def debug_mode
    git_config['review.mode'] == 'debug'
  end

  # Collect git config information in a Hash for easy access.
  # Checks '~/.gitconfig' for credentials.
  def git_config
    unless @git_config
      # Read @git_config from local git config.
      @git_config = {}
      config_list = git_call('config --list', false)
      config_list.split("\n").each do |line|
        key, value = line.split('=')
        @git_config[key] = value
      end
    end
    @git_config
  end

  # Returns an array consisting of information on the user and the project.
  def repo_info
    # Extract user and project name from GitHub URL.
    url = git_config['remote.origin.url']
    if url.nil?
      puts "Error: Not a git repository."
      return [nil, nil]
    end
    user, project = github_user_and_project(url)
    # If there are no results yet, look for 'insteadof' substitutions in URL and try again.
    unless (user and project)
      short, base = github_insteadof_matching(config_hash, url)
      if short and base
        url = url.sub(short, base)
        user, project = github_user_and_project(url)
      end
    end
    [user, project]
  end

  # Looks for 'insteadof' substitutions in URL.
  def github_insteadof_matching(config_hash, url)
    first = config_hash.collect { |key,value|
      [value, /url\.(.*github\.com.*)\.insteadof/.match(key)]
    }.find { |value, match|
      url.index(value) and match != nil
    }
    first ? [first[0], first[1][1]] : [nil, nil]
  end

  # Extract user and project name from GitHub URL.
  def github_user_and_project(github_url)
    matches = /github\.com.(.*?)\/(.*)/.match(github_url)
    matches ? [matches[1], matches[2].sub(/\.git\z/, '')] : [nil, nil]
  end

end
