# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

import sys
import os

sys.path.insert(
    0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))
)

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = "Boombox"
copyright = "2025, Software Mansion"
author = "Membrane Framework Team"

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

extensions = [
    "sphinx.ext.autodoc",
    "sphinx.ext.viewcode",
    "sphinx.ext.todo",
    "numpydoc",
]

templates_path = ["_templates"]
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

language = "en"

# Napoleon settings
# napoleon_google_docstring = True
# napoleon_numpy_docstring = True
# napoleon_include_init_with_doc = False
# napoleon_include_private_with_doc = False
# napoleon_include_special_with_doc = True
# napoleon_use_admonition_for_examples = True
# napoleon_use_admonition_for_notes = True
# napoleon_use_admonition_for_references = True
# napoleon_use_ivar = True
# napoleon_use_param = True
# napoleon_use_rtype = True
# napoleon_preprocess_types = True

# Autodoc settings
autodoc_member_order = "bysource"

# Autosummary settings
autosummary_generate = False

# Numpydoc settings
numpydoc_show_class_members = False

# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

html_theme = "sphinx_rtd_theme"
html_static_path = ["_static"]

# -- Options for todo extension ----------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/extensions/todo.html#configuration

todo_include_todos = True
