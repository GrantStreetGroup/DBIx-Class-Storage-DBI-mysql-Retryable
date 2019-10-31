use GSG::Gitc::CPANfile $_environment;

requires 'DBD::mysql';
requires 'DBI';
requires 'DBIx::Class';

on develop => sub {
    requires 'Dist::Zilla::PluginBundle::Author::GSG::Internal';
};
