require_relative "../../test_helper"

SingleCov.covered!

describe Kubernetes::Role do
  include GitRepoTestHelper

  def write_config(file, content)
    Dir.chdir(repo_temp_dir) do
      dir = File.dirname(file)
      Dir.mkdir(dir) if file.include?("/") && !File.exist?(dir)
      File.write(file, content)
    end
    commit
  end

  def commit
    execute_on_remote_repo <<-SHELL
        git add .
        git commit -m "second commit"
    SHELL
  end

  let(:role) { kubernetes_roles(:app_server) }
  let(:project) { role.project }
  let(:config_content) do
    [
      {
        'kind' => 'Deployment',
        'metadata' => {'labels' => {'role' => 'ROLE1'}},
        'strategy_type' => 'RollingUpdate'
      },
      {
        'kind' => 'Service',
        'metadata' => {'name' => 'SERVICE-NAME'}
      }
    ]
  end
  let(:config_content_yml) { config_content.map(&:to_yaml).join("\n") }

  describe 'validations' do
    it 'is valid' do
      assert_valid role
    end

    it 'is valid with known deploy strategy' do
      Kubernetes::Role::DEPLOY_STRATEGIES.each do |strategy|
        role.deploy_strategy = strategy
        assert_valid role
      end
    end

    it 'is invalid with unknown deploy strategy' do
      [nil, 'foo'].each do |strategy|
        role.deploy_strategy = strategy
        refute_valid role
      end
    end

    describe "service name" do
      let(:other) { kubernetes_roles(:resque_worker) }

      before do
        other.update_column(:service_name, 'abc')
        role.service_name = 'abc'
      end

      it "is invalid with a already used service name" do
        refute_valid role
      end

      it "is valid with a already used service name that was deted" do
        other.soft_delete!
        assert_valid role
      end
    end
  end

  describe '.seed' do
    before do
      create_repo_without_tags
      project.repository_url = repo_temp_dir
      Kubernetes::Role.delete_all
    end

    describe "with a correct role config" do
      before { write_config 'kubernetes/a.yml', config_content_yml }

      it 'creates a role' do
        Kubernetes::Role.seed! project, 'HEAD'
        project.kubernetes_roles.map(&:config_file).must_equal ["kubernetes/a.yml"]
      end

      it 'does not create duplicate roles' do
        Kubernetes::Role.seed! project, 'HEAD'
        Kubernetes::Role.seed! project, 'HEAD'
        project.kubernetes_roles.map(&:config_file).must_equal ["kubernetes/a.yml"]
      end
    end

    describe "without a service" do
      before do
        config_content.pop
        write_config 'kubernetes/a.json', config_content.to_json
      end

      it 'creates a role' do
        Kubernetes::Role.seed! project, 'HEAD'
        project.kubernetes_roles.map(&:service_name).must_equal [nil]
      end

      it 'creates a role when another role without service already exists' do
        Kubernetes::Role.create!(
          project: project,
          config_file: 'sdfsdf.yml',
          name: 'sdfsdf',
          service_name: nil,
          deploy_strategy: 'RollingUpdate'
        )
        Kubernetes::Role.seed! project, 'HEAD'
        project.kubernetes_roles.map(&:service_name).must_equal [nil, nil]
      end
    end

    it "reads other file types" do
      write_config 'kubernetes/a.json', config_content.to_json
      Kubernetes::Role.seed! project, 'HEAD'
      project.kubernetes_roles.map(&:config_file).must_equal ["kubernetes/a.json"]
    end

    it "does not read other files" do
      write_config 'kubernetes.yml', config_content_yml
      write_config 'foobar/kubernetes.yml', config_content_yml
      Kubernetes::Role.seed! project, 'HEAD'
      project.kubernetes_roles.must_equal []
    end

    it "does nothing on error" do
      Kubernetes::Role.seed! project, 'DFSDSFSDFD'
      project.kubernetes_roles.must_equal []
    end

    it "can seed duplicate service names" do
      write_config 'kubernetes/a.yml', config_content_yml
      write_config 'kubernetes/b.yml', config_content_yml
      Kubernetes::Role.seed! project, 'HEAD'
      names = project.kubernetes_roles.map(&:service_name).sort
      names.first.must_equal "SERVICE-NAME"
      names.last.must_match /SERVICE-NAME-CHANGE-ME-\d+/
    end

    it "can seed without role label" do
      assert config_content.first.fetch('metadata').delete('labels')
      write_config 'kubernetes/a.json', config_content.to_json
      Kubernetes::Role.seed! project, 'HEAD'
      project.kubernetes_roles.map(&:config_file).must_equal ["kubernetes/a.json"]
    end
  end

  describe '.configured_for_project' do
    before do
      create_repo_without_tags
      project.repository_url = repo_temp_dir
      write_config role.config_file, config_content_yml
    end

    it "finds all roles that are deployed" do
      Kubernetes::Role.configured_for_project(project, 'HEAD').must_equal [role]
    end

    it "raises when a role is in the repo, but not configured" do
      role.soft_delete!
      assert_raises Samson::Hooks::UserError do
        Kubernetes::Role.configured_for_project(project, 'HEAD')
      end
    end
  end

  describe "#label_name" do
    it "is url safe" do
      role.name = 'ÍÎapp_server'
      role.label_name.must_equal 'iiapp_server'
    end
  end

  describe '#defaults' do
    before do
      config_content[0]['spec'] = {
        'replicas' => 1, 'template' => {'spec' => {'containers' => [
          {'resources' => {'limits' => {'ram' => '200M', 'cpu' => '250m'}}}
        ]}}
      }
      GitRepository.any_instance.stubs(file_content: config_content_yml)
    end

    it "find defaults" do
      role.defaults.must_equal cpu: 0.25, ram: 200, replicas: 1
    end

    {
      '10000000' => 10,
      '10000000000m' => 10,
      '10000K' => 10,
      '10000Ki' => 10,
      '10M' => 10,
      '10Mi' => 10,
      '10G' => 10 * 1024,
      '10.5G' => 10.5 * 1024,
      '10Gi' => 9537,
    }.each do |ram, expected|
      it "converts ram units #{ram}" do
        assert config_content_yml.sub!('200M', ram)
        role.defaults.try(:[], :ram).must_equal expected
      end
    end

    it "ignores unknown units" do
      assert config_content_yml.sub!('200M', '200T')
      role.defaults.must_equal nil
    end

    it "ignores when there is no config" do
      GitRepository.any_instance.stubs(file_content: nil)
      role.defaults.must_equal nil
    end

    it "ignores when there is no deployable" do
      assert config_content_yml.sub!('Deployment', 'Deploymentx')
      refute role.defaults
    end
  end
end
