use GSG::Gitc::CPANfile $_environment;

# Direct requirements
requires 'Context::Preserve';
requires 'namespace::clean';

# Indirect (or bundled) requirements
requires 'DBI';
requires 'DBD::mysql';
requires 'DBIx::Class';

# Test requirements
test_requires 'Class::Load';
test_requires 'Path::Class';
test_requires 'Test2::Suite';

on develop => sub {
    requires 'Dist::Zilla::PluginBundle::Author::GSG::Internal';
};
